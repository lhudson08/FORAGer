#!/usr/bin/env perl

### modules
use strict;
use warnings;
use Pod::Usage;
use Data::Dumper;
use Getopt::Long;
use File::Spec;
use File::Path;
use File::Temp qw/ tempdir /;
use Set::IntervalTree;
use Storable;
use Parallel::ForkManager;
use Bio::DB::Sam;

### args/flags
pod2usage("$0: No files given.") if ((@ARGV == 0) && (-t STDIN));

my ($verbose, @sam_in, $index_in, $warnings_bool, $write_seqs_bool);
my $gene_extend = 100;
my $fork = 0;
my $outdir_name = "Mapped2Cluster";
my $index_setup;
GetOptions(
		"index=s" => \$index_in, 			# an index file of bam_file => FIG_of_ref-genome
		"extend=i" => \$gene_extend,		# bp to extend beyond gene (5' & 3')
		"outdir=s" => \$outdir_name, 		# name of output directory
		"fork=i" => \$fork,					# number of forked processes
		"ITEP" => \$index_setup, 			# indexed as ITEP db_getClusterGeneInformation.py? [TRUE]
		"warnings" => \$warnings_bool, 		# write warnings to STDERR? [TRUE]
		"sequences" => \$write_seqs_bool, 	# writing fasta for each cluter [TRUE]
	   "verbose" => \$verbose,
	   "help|?" => \&pod2usage # Help
	   );

### I/O error & defaults
die " ERROR: provide an index file!\n" unless $index_in;

### MAIN
# pulling out reads mapping to each gene region #
my $index_r = load_index($index_in);

# loading gene info #
my $gene_start_stop_r = load_gene_info($index_r, $index_setup);

# foreach query: get mapped reads #
my $pm = new Parallel::ForkManager($fork);
foreach my $query_reads (keys %$index_r){			
	print STDERR "### Processing indexed BAM files with reads from: $query_reads ###\n"
		unless $query_reads eq "SINGLE_QUERY";

	# making tmp data directory #
	my $tmp_dir_o = File::Temp->newdir();
	my $tmp_dir = $tmp_dir_o->dirname;
	
	# foreach BAM file (can fork & merge) # 
	foreach my $bam_file (keys %{$index_r->{$query_reads}}){
		my (%reads_mapped, %mapped_summary);
	
		# forking #
		$pm->start and next;
	
		# checking for presence of genes in fig #
		unless (exists $gene_start_stop_r->{$index_r->{$query_reads}{$bam_file}}){
			print STDERR " WARNING: none of the genes of interest are in FIG->", $index_r->{$query_reads}{$bam_file}, ", skipping\n";
			$pm->finish;
			next;
			}
	
		# finding mapped reads #
		reads_mapped_to_region($bam_file, $index_r->{$query_reads}{$bam_file}, 
			$gene_start_stop_r, $gene_extend, \%reads_mapped, \%mapped_summary);	
	
		# saving data structures #
		my @parts = File::Spec->splitpath($bam_file);
		$parts[2] =~ s/\.[^.]+$//;
		store(\%reads_mapped, "$tmp_dir/$parts[2]\_map");
		store(\%mapped_summary, "$tmp_dir/$parts[2]\_sum");
	
		# end fork #
		$pm->finish;
		}

	$pm->wait_all_children;		# waiting all children for query

	# merging hashes #
	my ($mapped_r, $summary_r) = merge_hashes($tmp_dir);

	# writing output #
	my $outdir_name_e = make_outdir($outdir_name, $query_reads);
	write_reads_mapped($mapped_r, $outdir_name_e);
	write_summary_table($summary_r, $outdir_name_e);
	}


#---------- Subroutines -----------#
sub write_summary_table{
# writing summary table on reads mapped to FIGs for each gene cluster #
	my ($mapped_summary_r, $outdir_name) = @_;
	
	open OUT, ">$outdir_name/mapped_summary.txt" or die $!;
	
	# header #
	print OUT join("\t", qw/Cluster FIG N_reads Gene_length_nuc Mean_coverage Stdev_coverage/), "\n";
	
	# body #
	foreach my $cluster (keys %$mapped_summary_r){
		foreach my $fig (keys %{$mapped_summary_r->{$cluster}}){
			# writing line #
			print OUT join("\t", $cluster, $fig, 
				$mapped_summary_r->{$cluster}{$fig}{"count"},			# number of reads mapped
				$mapped_summary_r->{$cluster}{$fig}{"length"},			# length of gene
				$mapped_summary_r->{$cluster}{$fig}{"coverage_mean"},		# mean coverage
				$mapped_summary_r->{$cluster}{$fig}{"coverage_stdev"}		# stdev of coverage
				), "\n"; 											# reads/length
			}
		}
	
	close OUT;
	
	print STDERR "...summary file written: $outdir_name/mapped_summary.txt\n"
		unless $verbose;
	}

sub write_reads_mapped{
# writing out all reads mapped #
	my ($reads_mapped_r, $outdir_name) = @_;
	
	# status #
	print STDERR "...writing out read files to $outdir_name\n" unless $verbose;
	
	foreach my $cluster (keys %$reads_mapped_r){
		(my $outfile = $cluster) =~ s/^/clust/;
		open OUTP, ">$outdir_name/$outfile\_FR.fna" or die $!;
		open OUTA, ">$outdir_name/$outfile\_A.fna" or die $!;
		
		foreach my $read (keys %{$reads_mapped_r->{$cluster}}){
			# paired-end reads #
			if(exists $reads_mapped_r->{$cluster}{$read}{0} && 
				exists $reads_mapped_r->{$cluster}{$read}{1}){ 
				foreach my $pair (sort keys %{$reads_mapped_r->{$cluster}{$read}}){
					foreach my $mapID (keys %{$reads_mapped_r->{$cluster}{$read}{$pair}}){
						print OUTP join("\n", ">$read $pair:", $reads_mapped_r->{$cluster}{$read}{$pair}{$mapID}), "\n";
						last; 		# just 1st map ID
						}
					}
				}
			# all reads #
			foreach my $pair (sort keys %{$reads_mapped_r->{$cluster}{$read}}){
				foreach my $mapID (keys %{$reads_mapped_r->{$cluster}{$read}{$pair}}){
					print OUTA join("\n", ">$read $pair:", $reads_mapped_r->{$cluster}{$read}{$pair}{$mapID}), "\n";
					last;			# just 1st mapID
					}
				}
			}
		close OUTP;
		close OUTA;
		}
	}

sub make_outdir{
# making output directory #
	my ($outdir_name, $query_reads) = @_;
	
	$outdir_name .= "_$query_reads" unless $query_reads eq "SINGLE_QUERY";
	
	$outdir_name = File::Spec->rel2abs($outdir_name);

	rmtree($outdir_name) if -d $outdir_name;
	mkdir $outdir_name or die $!;
	
	return $outdir_name;
	}

sub merge_hashes{
# merging mapped & summary hashes #
# each hash has reads mapped to cluster for 1 FIG #
	my ($tmp_dir) = @_;
	
	# status #
	print STDERR "...merging hashes from forks\n" unless $verbose;
	
	# getting mapping files #
	opendir IN, $tmp_dir or die $!;
	my @map_files = grep(/_map/, readdir IN);
	closedir IN;

	# merging hashes #
	my %mapped;
	foreach my $infile (@map_files){
		my $href = retrieve("$tmp_dir/$infile");

		foreach my $clust (keys %$href){
			if(exists $mapped{$clust}){
				# adding reads not already present in cluster #
				foreach my $read (keys %{$href->{$clust}}){
					foreach my $pair (keys %{$href->{$clust}{$read}}){
						$mapped{$clust}{$read}{$pair} = $href->{$clust}{$read}{$pair}
							unless exists $mapped{$clust}{$read}{$pair};
						}
					}
				}
			else{ $mapped{$clust} = $href->{$clust}; }		# adding whole cluster to mapped
			}
		}	


	# getting summary files #
	opendir IN, $tmp_dir or die $!;
	my @sum_files = grep(/_sum/, readdir IN);
	closedir IN;

	# merging hashes #
	my %summed;
	foreach my $infile (@sum_files){
		my $href = retrieve("$tmp_dir/$infile");	#cluster->fig->cat->value
		foreach my $clust (keys %$href){
			if(exists $summed{$clust}){
				# adding figs not already present in cluster #
				foreach my $fig (keys %{$href->{$clust}}){
					$summed{$clust}{$fig} = $href->{$clust}{$fig}
						unless exists $summed{$clust}{$fig};
					}
				}
			else{ $summed{$clust} = $href->{$clust}; }		# adding whole cluster to mapped
			}
		}		

		#print Dumper %mapped; #exit;
	return \%mapped, \%summed;
	}

sub reads_mapped_to_region{
# parsing out reads of 1 query that mapped to each gene region of a subject #
## $gene_start_stop_r = fig=>cluster=>contig=>start/stop=>value
## foreach gene (start-stop): find reads mapped to gene (from itree) 

	my ($bam_file, $fig, $gene_start_stop_r, 
		$gene_extend, $reads_mapped_r, $mapped_summary_r) = @_;

	# status #
	print STDERR "...finding reads mapped to genes of interest in: FIG$fig\n"
		unless $verbose;

	# loading bam object #
	my $bamo = Bio::DB::Sam->new(-bam => $bam_file);

	my %warnings;
		# gene_start_stop = fig->clust->contig->cat->value
	foreach my $cluster (keys %{$gene_start_stop_r->{$fig}}){					# gene clusters in FIG
		foreach my $contig (keys %{$gene_start_stop_r->{$fig}{$cluster}}){		# contig 
			# gene start-end #
			my $gene_start = $gene_start_stop_r->{$fig}{$cluster}{$contig}{"start"};
			my $gene_end = $gene_start_stop_r->{$fig}{$cluster}{$contig}{"end"};
			($gene_start, $gene_end) = flip_se($gene_start, $gene_end)
				if $gene_start_stop_r->{$fig}{$cluster}{$contig}{"strand"} eq "-";
			
			# fetching alignments (mapped reads) for query gene #
			my @alignments = $bamo->get_features_by_location(-seq_id => $contig,
																-type => 'read_pair',
																-start => $gene_start,
																-end => $gene_end);
			
			# fetching coverage of mapped reads for query gene #
			my $cov = $bamo->get_features_by_location(-seq_id => $contig,
																-type => 'coverage',
																-start => $gene_start,
																-end => $gene_end);
			my @cov = $bamo->features(-type => 'coverage', -seq_id => $contig, -start => $gene_start, -end => $gene_end);
			

			# summarizing #
			if(@alignments){
				$mapped_summary_r->{$cluster}{$fig}{"count"} += scalar @alignments;
				$mapped_summary_r->{$cluster}{$fig}{"length"} = abs($gene_end - $gene_start);				
				
				$mapped_summary_r->{$cluster}{$fig}{"coverage_mean"} = average([$cov[0]->coverage]);
				$mapped_summary_r->{$cluster}{$fig}{"coverage_stdev"} = stdev([$cov[0]->coverage]);								
				}
			else{
				print STDERR "WARNING: no reads mapped to FIG:$fig -> Contig:$contig -> cluster:$cluster\n"
					unless $warnings_bool;
				
				$mapped_summary_r->{$cluster}{$fig}{"count"} += 0;
				$mapped_summary_r->{$cluster}{$fig}{"length"} = abs($gene_end - $gene_start);

				$mapped_summary_r->{$cluster}{$fig}{"coverage_mean"} = 0;
				$mapped_summary_r->{$cluster}{$fig}{"coverage_stdev"} = 0;
				
				next;
				}

			# loading read names #
			foreach my $aln (@alignments){		# read IDs
				# cluster->read_ID->pair->mapID = read
				my (@pairs) = $aln->get_SeqFeatures;
				for my $i (0..$#pairs){
					$reads_mapped_r->{$cluster}{$pairs[$i]->name}{$i}{"$fig\__$contig"} = $pairs[$i]->seq->seq;
					}
				
				#print Dumper $aln->seq;
				#print Dumper $aln->query->seq_id;
				#print Dumper $aln->query->dna;
				#print Dumper $aln->get_tag_values('PAIRED');
				#print Dumper $aln;
				#$reads_mapped_r->{$cluster}{$$id[0]}{$$id[1]}{"$fig\__$$id[2]"} = $$id[3];
			#	$reads_mapped_r->{$cluster}{$aln->name}{  }{  } = $aln->seq->seq;
				}			
			}
		}	
	
		#print Dumper %$reads_mapped_r; exit;
		#print Dumper %$mapped_summary_r; exit;
	sub flip_se{
		my ($start, $end) = @_;
		return $end, $start;
		}
	}

sub reads_mapped_to_region_OLD{
# parsing out reads that mapped to each gene region #
## $gene_start_stop_r = fig=>cluster=>contig=>start/stop=>value
## foreach gene (start-stop): find reads mapped to gene (from itree) 

	my ($bam_file, $fig, $gene_start_stop_r, 
		$gene_extend, $itrees_r, $reads_r, 
		$reads_mapped_r, $mapped_summary_r) = @_;

	# status #
	print STDERR "...finding reads mapped to genes in FIG$fig\n"
		unless $verbose;

	my %warnings;
	
	foreach my $cluster (keys %{$gene_start_stop_r->{$fig}}){					# gene clusters in FIG
		foreach my $contig (keys %{$gene_start_stop_r->{$fig}{$cluster}}){
			# contig of gene in gene tree? #
			unless(exists $itrees_r->{$contig}){
				print STDERR "WARNING: no reads mapped to FIG:$fig -> CONTIG:$contig\n"
					unless $warnings_bool || exists $warnings{$fig}{$contig};		
				$warnings{$fig}{$contig} = 1;				# so the warning only needs to be given once
				next;
				}
			
			# fetching reads spanning start-stop (reads only have to partially overlap the gene region)
			my $res = $itrees_r->{$contig}->fetch(
					$gene_start_stop_r->{$fig}{$cluster}{$contig}{"start"} - $gene_extend,
					$gene_start_stop_r->{$fig}{$cluster}{$contig}{"stop"} + $gene_extend
					);
			
			# if no reads found: #
			unless(@$res){
				print STDERR "WARNING: no reads mapped to FIG:$fig -> Contig:$contig -> cluster:$cluster\n"
					unless $warnings_bool;
				$mapped_summary_r->{$cluster}{$fig}{"count"} += scalar @$res;
				$mapped_summary_r->{$cluster}{$fig}{"length"} = 0;
				next;
				}
			
			# loading read names #
			foreach my $id (@$res){		# read IDs
				$reads_mapped_r->{$cluster}{$$id[0]}{$$id[1]}{"$fig\__$$id[2]"} = $$id[3];		# cluster->read_ID->pair->mapID = read
				}
				
			# loading summary (summing number of reads per gene) #
			$mapped_summary_r->{$cluster}{$fig}{"count"} += scalar @$res;
			$mapped_summary_r->{$cluster}{$fig}{"length"} =
				($gene_start_stop_r->{$fig}{$cluster}{$contig}{"stop"} + $gene_extend) - 
				($gene_start_stop_r->{$fig}{$cluster}{$contig}{"start"} - $gene_extend)
				unless exists $mapped_summary_r->{$cluster}{$fig}{"length"};
				# cluster->fig->cat->value
			}
		}
		
		#print Dumper %$reads_mapped_r; exit;
		#print Dumper %$mapped_summary_r; exit;
	}
	
sub open_file{
# check for compression; open depending on the file extension; return filehandle #
	my $file = shift;
	
	my $fh;
	if(-B $file and $file =~ /tgz$|tar.gz$/){		# if file is compressed
		open($fh, "-|", "zcat $file | tar  -O -xf -") or die $!;
		}
	elsif(-B $file and $file =~ /.gz$/){			# if file is gzipped
		open($fh, "-|", "zcat $file") or die $!;
		}
	else{
		open $fh, $file or die $!;
		}
	
	return $fh;
	}

sub load_index{
# loading index file (query => sam => FIG#) #
	my ($index_in) = @_;
	
	open IN, $index_in or die $!;
	my %index;
	while(<IN>){
		chomp;
		s/#.+//;
		next if /^\s*$/;
		
		my @line = split /\t/;
		$line[0] = File::Spec->rel2abs($line[0]);

		unless (-e $line[0]){
			print STDERR " WARNING: $line[0] does not exist!\n";
			next;
			}

		# loading hash #
		if($line[3]){	# if query name provided
			$index{$line[3]}{$line[0]} = $line[2];				# query => bam/cat => value
			$index{$line[3]}{"__SUBJECT_FASTA__"} = $line[1];						
			}
		else{
			$index{"__SINGLE_QUERY__"}{$line[0]}{"subject_FIG"} = $line[2];		# query => bam/cat => value
			$index{"__SINGLE_QUERY__"}{"__SUBJECT_FASTA__"} = $line[1];			
			}
		}
	close IN;

		#print Dumper %index; exit;
	return \%index;
	}

sub load_gene_info{
# loading gene info: either ITEP or 'minimal' table indexing #
#--- standard ---#
## taxon_ID			(same as index)
## subject_contig_ID
## subject_gene_start
## subject_gene_end
## subject_gene_strand
## subject_gene_cluster
	my ($index_r, $index_setup) = @_;
	

	# parsing gene info table from STDIN #
	my %gene_start_stop;
	my (%fna, %faa);		# fasta ouput of clusters (nuc & aa)
	while(<>){	
		chomp;
		next if /^\s*$/;
		
		# parsing #
		my @line = split /\t/;
		die " ERROR: row in gene info table must have >= 6 columns!\n"
			unless scalar @line >= 6;
		die " ERROR: clustID column should be integers in the last row of the ClusterGeneInformation table\n"
			unless $line[$#line] =~ /^\d+$/;
		
		# setting indexing #
		my ($FIG, $contig, $start, $end, $strand, $cluster);
		if($index_setup){		# 'minimal'
			$FIG = $line[0];			# gene FIG_ID
			$contig = $line[1];			# contig of Subject
			$start = $line[2];
			$end = $line[3];
			$strand = $line[4];
			$cluster = $line[5];			
			}
		else{					# ITEP
			($FIG = $line[0]) =~ s/fig\||\.peg.+//g;
			($contig = $line[4]) =~ s/^$line[2]\.//;
			$start = $line[5];
			$end = $line[6];
			$strand = $line[7];
			$cluster = $line[$#line];
			}	
		
		# loading hash #
		$gene_start_stop{$FIG}{$cluster}{$contig}{"start"} = $start;
		$gene_start_stop{$FIG}{$cluster}{$contig}{"end"} = $end;
		$gene_start_stop{$FIG}{$cluster}{$contig}{"strand"} = $strand;

		## loading sequences ##
		$fna{$line[13]}{$line[0]} = $line[10];
		$faa{$line[13]}{$line[0]} = $line[11];
	}
	
	# sanity check #
	die " ERROR: no gene information found for gene clusters!\n" if
		scalar keys %gene_start_stop == 0;		

	# writing out fasta files #
	unless($write_seqs_bool){
		write_cluster_fasta(\%fna, "nuc");
		write_cluster_fasta(\%faa, "aa");
		print STDERR "\n" unless $verbose;
		}	
		
	# counting clusters (in provided FIGs) #
	## getting all figs ##
	my @figs;
	foreach my $q (keys %$index_r){
		foreach my $bam (keys %{$index_r->{$q}}){
			next if $bam eq "__SUBJECT_FASTA__";
			push(@figs, $index_r->{$q}{$bam});
			}
		}

	## counting clusters ##
	my %cnt;
	foreach my $fig (@figs){
		print STDERR " WARNING: FIG $fig not found in provided gene cluster info!\n"
			unless exists $gene_start_stop{$fig} || $warnings_bool; 
		map{ $cnt{$_}=1 } keys %{$gene_start_stop{$fig}};
		}
	print STDERR "Number of clusters containing genes from provided FIGs: ", scalar keys %cnt, "\n";

		#print Dumper %gene_start_stop; exit;
	return \%gene_start_stop;		# fig=>cluster=>contig=>start/stop=>value	
									# FIG = gene figID
	}

sub write_cluster_fasta{
# writing fasta files for each cluster #
	my ($fasta_r, $type) = @_;

	# variables by types
	my $outdir;
	if($type eq "nuc"){ $outdir = "cluster_nuc";}
	elsif($type eq "aa"){ $outdir = "cluster_aa"; }
	else{ die " LOGIC ERROR: $!\n"; }
	
	# making directory #
	$outdir = File::Spec->rel2abs($outdir);
	rmtree($outdir) if -d $outdir;
	mkdir $outdir or die $!;
	
	# writing cluster fasta files #
	foreach my $clust (keys %$fasta_r){
		open OUT, ">$outdir/clust$clust.fasta" or die $!;
		
		foreach my $seq (keys %{$fasta_r->{$clust}}){
			print OUT join("\n", ">$seq", $fasta_r->{$clust}{$seq}), "\n";
			}
		close OUT;
		}
		
	# status #
	print STDERR "...fasta for each cluster written to $outdir\n" unless $verbose;
	}


sub average{
        my($data) = @_;
        if (not @$data) {
                die("Empty array\n");
        }
        my $total = 0;
        foreach (@$data) {
                $total += $_;
        }
        my $average = $total / @$data;
        return $average;
}
sub stdev{
        my($data) = @_;
        if(@$data == 1){
                return 0;
        }
        my $average = &average($data);
        my $sqtotal = 0;
        foreach(@$data) {
                $sqtotal += ($average-$_) ** 2;
        }
        my $std = ($sqtotal / (@$data-1)) ** 0.5;
        return $std;
}


__END__

=pod

=head1 NAME

FORAGer.pl -- Finding Orthologous Reads and Genes

=head1 SYNOPSIS

db_getClusterGeneInformation.py | FORAGer.pl [flags]

=head2 Required flags

=over

=item -index

Index file listing *sam files & FIG IDs.

2 (or 3) column format (*txt): 1st=/PATH_to_FILE/FILE.sam; 2nd=FIG; (3rd=Query)

=back

=head2 Optional flags

=over

=item -outdir

Output directory name (location of all mapped read files). 
For multiple queries, querie names will be appended to the directory
name. [./Mapped2Cluster/]

=item -sequences

Write out fasta nucleotide & amino acid files for all gene clusters
provided? [TRUE]

=item -extend

Number of base pairs to extend around the gene of interest (5' & 3'). [100]

=item -fork

Number of BAM files to process in parallel. [1]

=item -ITEP

Piped input indexed as ITEP db_getClusterGeneInformation.py? [TRUE]


=item -verbose

Verbose output. [TRUE]

=item -warnings

Display warnings. [TRUE]

=item -help

This help message.

=back

=head2 For more information:

perldoc FORAGer.pl

=head1 DESCRIPTION

Pull out all reads mapping to each gene (& region around the gene)
in each gene cluster. Query reads from multiple draft genomes
can be mapped onto multple and draft/closed
reference genomes (just need to make an index file).

=head2 Input

=head3 Index file

2 or 3 column tab-delimited file for associating a BAM file to 
the FIG ID of the reference genome used for mapping. 'Query' (3rd column)
is only needed if multiple query draft genomes were used for read
mapping.

1st=/PATH_to_FILE/FILE.sam;  2nd=FIG; (3rd=Query)

=head3 db_getClusterGeneInformation.py | 

Piped output from db_getClusterGeneInformation.py.

Clusters should be from 1 cluster run!

output from 

=head3 BAM files

Reads from a genome of interest (e.g. a draft genome) should be mapped
onto all other genomes (producing the BAM files required).

You do not need to provide a *bam file for each FIG in each gene cluster;
however, genes from any genomes lacking *sam files will be skipped (ie. 
no reads pulled out for those genes; less total reads for the local assembly)

Multiple mappings are allowed for the same file (e.g. bowtie2 with '-k' flag).

=head2 Output files

All files output to a directory(s). See '-outdir'.

=head3 read files

File prefix = 'clust#'

'_FR.fna' = Just paired-end reads that both mapped to the gene region

'_A.fna' = All reads that mapped to the gene region

=head3 summary file

"*summary.txt"

Output: Cluster_ID, FIG_ID, Number_of_reads_mapped, Gene_length, Reads_by_length

=head2 Requires

ITEP must be set up, so that it can be queried. 

=head1 EXAMPLES

=head2 Mapping reads to a reference genome

$ bowtie2-build genome1.fna genome1

$ bowtie2 -x genome1 -S genome1.sam -1 reads_F.fq -2 reads_R.fq -k 10

=head2 Make an index file

column1 = *bam file location

column2 = FIG ID

=head2 Get some gene clusters of interest

$ db_getAllClusterRuns.py | grep "mazei_I_2.0_c_0.4_m_maxbit" | 
db_getClustersWithAnnotation.py "methyl coenzyme M reductase" |
db_getClusterGeneInformation.py | FORAGer.pl -in index.txt 
-runID all_I_2.0_c_0.4_m_maxbit

=head1 AUTHOR

Nick Youngblut <nyoungb2@illinois.edu>

=head1 AVAILABILITY

sharchaea.life.uiuc.edu:/home/git/ITEP_PopGen/

=head1 COPYRIGHT

Copyright 2010, 2011
This software is licensed under the terms of the GPLv3

=cut


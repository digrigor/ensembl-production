=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

=pod


=head1 CONTACT

  Please email comments or questions to the public Ensembl
  developers list at <http://lists.ensembl.org/mailman/listinfo/dev>.

  Questions may also be sent to the Ensembl help desk at
  <http://www.ensembl.org/Help/Contact>.

=head1 NAME

Bio::EnsEMBL::Production::Pipeline::GTF::DumpFile

=head1 DESCRIPTION

The main workhorse of the GTF dumping pipeline.

Allowed parameters are:

=over 8

=item species - The species to dump

=item base_path - The base of the dumps

=item release - The current release we are emitting

=back

=cut

package Bio::EnsEMBL::Production::Pipeline::GTF::DumpFile;

use strict;
use warnings;

use base qw(Bio::EnsEMBL::Production::Pipeline::GTF::Base);

use Bio::EnsEMBL::Utils::Exception qw/throw/;
use Bio::EnsEMBL::Utils::IO qw/work_with_file gz_work_with_file/;
use Bio::EnsEMBL::Utils::IO::GTFSerializer;
use File::Path qw/rmtree/;

sub param_defaults {
  return {
    group => 'core',
  };
}

sub fetch_input {
  my ($self) = @_;
  
  my $eg = $self->param('eg');
  $self->param('eg', $eg);

  if($eg){
     my $base_path = $self->param('sub_dir');
     $self->param('base_path', $base_path);
 
     my $release = $self->param('eg_version');    
     $self->param('release', $release);
  } 
  
  throw "Need a species" unless $self->param('species');
  throw "Need a release" unless $self->param('release');
  throw "Need a base_path" unless $self->param('base_path');

  if(!$eg){
   throw "No gtfToGenePred executable given" 
    unless $self->param('gtf_to_genepred');
   $self->assert_executable($self->param('gtf_to_genepred'));

   throw "No genePredCheck executable given" 
    unless $self->param('gene_pred_check');
   $self->assert_executable($self->param('gene_pred_check'));
  }

  return;
}

sub run {
  my ($self) = @_;

  my $eg   = $self->param('eg');  
  my $root = $self->data_path();
  if(-d $root) {
    $self->info('Directory "%s" already exists; removing', $root);
    rmtree($root);
  }

  my $path = $self->_generate_file_name();
  $self->info("Dumping GTF to %s", $path);
  gz_work_with_file($path, 'w', sub {
    my ($fh) = @_;
    my $gtf_serializer = Bio::EnsEMBL::Utils::IO::GTFSerializer->new($fh);

    # Print information about the current assembly
    $gtf_serializer->print_main_header($self->get_DBAdaptor('core'));

    # now get all slices and filter for 1st portion of human Y
    my $slices = $self->get_Slices($self->param('group'), 1);
    while (my $slice = shift @{$slices}) {
      my $genes = $slice->get_all_Genes(undef,undef,1); 
      while (my $gene = shift @{$genes}) {
	#
	# WARNING
	#  Drosophila melanoganster specific hack.
	#  Gene FBgn0002781 is a complicated trans-spliced gene.
	#  For it, one particular exon is annotated on a strand 
	#  opposite to that of the gene.
	#
	#  Skip the annotation process in this case. 
	#
	next if $self->param('species') =~ /drosophila/i
	  and $gene->stable_id eq 'FBgn0002781';

        $gtf_serializer->print_Gene($gene);
      }
    }
  });

  $self->info(sprintf "Checking GTF file %s", $path);
  $self->_gene_pred_check($path) unless $eg;
  
  # $self->run_cmd("gzip $path");

  $self->info("Dumping GTF README for %s", $self->param('species'));
  $self->_create_README();  
  
  return;
}

sub _gene_pred_check {
  my ($self, $gtf_file) = @_;
  my $info_out = File::Spec->catfile($self->data_path(), 'info.out');
  my $genepred_out = File::Spec->catfile($self->data_path(), 'info.gp');

  my $cmd = sprintf(q{%s -infoOut=%s -genePredExt %s %s}, 
    $self->param('gtf_to_genepred'), $info_out, $gtf_file, $genepred_out);
  $self->run_cmd($cmd);

  $cmd = sprintf(q{%s %s}, $self->param('gene_pred_check'), $genepred_out);
  my ($rc, $output) = $self->run_cmd($cmd);

  throw sprintf "genePredCheck reports failure for %s GTF dump", $self->param('species')
    unless $output =~ /failed: 0/;

  unlink $info_out;
  unlink $genepred_out;

  return;
}

sub _generate_file_name {
  my ($self) = @_;

  # File name format looks like:
  # <species>.<assembly>.<release>.gtf.gz
  # e.g. Homo_sapiens.GRCh37.71.gtf.gz
  my @name_bits;
  push @name_bits, $self->web_name();
  push @name_bits, $self->assembly();
  push @name_bits, $self->param('release');
  push @name_bits, 'gtf', 'gz';

  my $file_name = join( '.', @name_bits );
  my $path = $self->data_path();

  return File::Spec->catfile($path, $file_name);

}

sub _create_README {
  my ($self) = @_;
  my $species = $self->scientific_name();
  
  my $readme = <<README;
#### README ####

--------
GTF DUMP
--------

This directory includes a summary of the gene annotation information 
and GTF format.

Ensembl provides an automatic gene annotation for $species.
For some species ( human, mouse, zebrafish and pig), the
annotation provided through Ensembl also includes manual annotation
from HAVANA. In the case of human this is the GENCODE gene set.

GTF provides access to all annotated transcripts which make
up an Ensembl gene set. Annotation is based on alignments of
biological evidence (eg. proteins, cDNAs, RNA-seq) to a genome assembly.
The annotation dumped here is transcribed and translated from the 
genome assembly and is not the original input sequence data that 
we used for alignment. Therefore, the sequences provided by Ensembl 
may differ from the original input sequence data where the genome 
assembly is different to the aligned sequence. 

--------------------------------
Definition and supported options
--------------------------------

The GTF (General Transfer Format) is an extension of GFF version 2 
and used to represent transcription models. GFF (General Feature Format) 
consists of one line per feature, each containing 9 columns of data. 

Fields

Fields are tab-separated. Also, all but the final field in each 
feature line must contain a value; "empty" columns are denoted 
with a '.'

    seqname   - name of the chromosome or scaffold; chromosome names 
                without a 'chr' 
    source    - name of the program that generated this feature, or 
                the data source (database or project name)
    feature   - feature type name. Current allowed features are
                {gene, transcript, exon, CDS, Selenocysteine, start_codon,
                stop_codon and UTR}
    start     - start position of the feature, with sequence numbering 
                starting at 1.
    end       - end position of the feature, with sequence numbering 
                starting at 1.
    score     - a floating point value indiciating the score of a feature
    strand    - defined as + (forward) or - (reverse).
    frame     - one of '0', '1' or '2'. Frame indicates the number of base pairs
                before you encounter a full codon. '0' indicates the feature 
                begins with a whole codon. '1' indicates there is an extra
                base (the 3rd base of the prior codon) at the start of this feature.
                '2' indicates there are two extra bases (2nd and 3rd base of the 
                prior exon) before the first codon. All values are given with
                relation to the 5' end.
    attribute - a semicolon-separated list of tag-value pairs (separated by a space), 
                providing additional information about each feature. A key can be
                repeated multiple times.

Attributes

The following attributes are available. All attributes are semi-colon
separated pairs of keys and values.

- gene_id: The stable identifier for the gene
- gene_version: The stable identifier version for the gene
- gene_name: The official symbol of this gene
- gene_source: The annotation source for this gene
- gene_biotype: The biotype of this gene
- transcript_id: The stable identifier for this transcript
- transcript_version: The stable identifier version for this transcript
- transcript_name: The symbold for this transcript derived from the gene name
- transcript_source: The annotation source for this transcript
- transcript_biotype: The biotype for this transcript
- exon_id: The stable identifier for this exon
- exon_version: The stable identifier version for this exon
- exon_number: Position of this exon in the transcript
- ccds_id: CCDS identifier linked to this transcript
- protein_id: Stable identifier for this transcript's protein
- protein_version: Stable identifier version for this transcript's protein
- tag: A collection of additional key value tags
- transcript_support_level: Ranking to assess how well a transcript is supported (from 1 to 5)

Tags

Tags are additional flags used to indicate attibutes of the transcript.

- CCDS: Flags this transcript as one linked to a CCDS record
- seleno: Flags this transcript has a Selenocysteine edit. Look for the Selenocysteine
feature for the position of this on the genome
- cds_end_NF: the coding region end could not be confirmed
- cds_start_NF: the coding region start could not be confirmed
- mRNA_end_NF: the mRNA end could not be confirmed
- mRNA_start_NF: the mRNA start could not be confirmed.
- basic: the transcript is part of the gencode basic geneset

Comments

Lines may be commented out by the addition of a single # character at the start. These
lines should be ignored by your parser.

Pragmas/Metadata

GTF files can contain meta-data. In the case of experimental meta-data these are 
noted by a #!. Those which are stable are noted by a ##. Meta data is a single key,
a space and then the value. Current meta data keys are:

* genome-build -  Build identifier of the assembly e.g. GRCh37.p11
* genome-version - Version of this assembly e.g. GRCh37
* genome-date - The date of this assembly's release e.g. 2009-02
* genome-build-accession - The accession and source of this accession e.g. NCBI:GCA_000001405.14
* genebuild-last-updated - The date of the last genebuild update e.g. 2013-09

------------------
Example GTF output
------------------

#!genome-build GRCh38
11      ensembl_havana  gene    5422111 5423206 .       +       .       gene_id "ENSG00000167360"; gene_version "4"; gene_name "OR51Q1"; gene_source "ensembl_havana"; gene_biotype "protein_coding";
11      ensembl_havana  transcript      5422111 5423206 .       +       .       gene_id "ENSG00000167360"; gene_version "4"; transcript_id "ENST00000300778"; transcript_version "4"; gene_name "OR51Q1"; gene_source "ensembl_havana"; gene_biotype "protein_coding"; transcript_name "OR51Q1-001"; transcript_source "ensembl_havana"; transcript_biotype "protein_coding"; tag "CCDS"; ccds_id "CCDS31381";
11      ensembl_havana  exon    5422111 5423206 .       +       .       gene_id "ENSG00000167360"; gene_version "4"; transcript_id "ENST00000300778"; transcript_version "4"; exon_number "1"; gene_name "OR51Q1"; gene_source "ensembl_havana"; gene_biotype "protein_coding"; transcript_name "OR51Q1-001"; transcript_source "ensembl_havana"; transcript_biotype "protein_coding"; tag "CCDS"; ccds_id "CCDS31381"; exon_id "ENSE00001276439"; exon_version "4";
11      ensembl_havana  CDS     5422201 5423151 .       +       0       gene_id "ENSG00000167360"; gene_version "4"; transcript_id "ENST00000300778"; transcript_version "4"; exon_number "1"; gene_name "OR51Q1"; gene_source "ensembl_havana"; gene_biotype "protein_coding"; transcript_name "OR51Q1-001"; transcript_source "ensembl_havana"; transcript_biotype "protein_coding"; tag "CCDS"; ccds_id "CCDS31381"; protein_id "ENSP00000300778"; protein_version "4";
11      ensembl_havana  start_codon     5422201 5422203 .       +       0       gene_id "ENSG00000167360"; gene_version "4"; transcript_id "ENST00000300778"; transcript_version "4"; exon_number "1"; gene_name "OR51Q1"; gene_source "ensembl_havana"; gene_biotype "protein_coding"; transcript_name "OR51Q1-001"; transcript_source "ensembl_havana"; transcript_biotype "protein_coding"; tag "CCDS"; ccds_id "CCDS31381";
11      ensembl_havana  stop_codon      5423152 5423154 .       +       0       gene_id "ENSG00000167360"; gene_version "4"; transcript_id "ENST00000300778"; transcript_version "4"; exon_number "1"; gene_name "OR51Q1"; gene_source "ensembl_havana"; gene_biotype "protein_coding"; transcript_name "OR51Q1-001"; transcript_source "ensembl_havana"; transcript_biotype "protein_coding"; tag "CCDS"; ccds_id "CCDS31381";
11      ensembl_havana  UTR     5422111 5422200 .       +       .       gene_id "ENSG00000167360"; gene_version "4"; transcript_id "ENST00000300778"; transcript_version "4"; gene_name "OR51Q1"; gene_source "ensembl_havana"; gene_biotype "protein_coding"; transcript_name "OR51Q1-001"; transcript_source "ensembl_havana"; transcript_biotype "protein_coding"; tag "CCDS"; ccds_id "CCDS31381";
11      ensembl_havana  UTR     5423155 5423206 .       +       .       gene_id "ENSG00000167360"; gene_version "4"; transcript_id "ENST00000300778"; transcript_version "4"; gene_name "OR51Q1"; gene_source "ensembl_havana"; gene_biotype "protein_coding"; transcript_name "OR51Q1-001"; transcript_source "ensembl_havana"; transcript_biotype "protein_coding"; tag "CCDS"; ccds_id "CCDS31381";

README
  
  my $path = File::Spec->catfile($self->data_path(), 'README');
  work_with_file($path, 'w', sub {
    my ($fh) = @_;
    print $fh $readme;
    return;
  });
  return;
}

1;


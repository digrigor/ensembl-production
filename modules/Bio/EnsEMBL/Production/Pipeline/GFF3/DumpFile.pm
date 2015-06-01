=head1 LICENSE

Copyright [2009-2015] EMBL-European Bioinformatics Institute

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

package Bio::EnsEMBL::Production::Pipeline::GFF3::DumpFile;

use strict;
use warnings;
no  warnings 'redefine';
use base ('Bio::EnsEMBL::Production::Pipeline::GFF3::Base');

use Bio::EnsEMBL::Utils::Exception qw/throw/;
use Bio::EnsEMBL::Utils::IO::GFFSerializer;
use Bio::EnsEMBL::Utils::IO qw/work_with_file gz_work_with_file/;
use File::Path qw/rmtree/;
use Bio::EnsEMBL::Transcript;


my $add_xrefs = 0;#$self->param('xrefs');

sub param_defaults {
  my ($self) = @_;
  
  return {
    %{$self->SUPER::param_defaults},
    'feature_type'     => ['Gene', 'Transcript'],
    'data_type'        => 'basefeatures',
    'file_type'        => 'gff3',
    'per_chromosome'   => 0,
    'include_scaffold' => 1,
    'logic_name'       => [],
  };
}

sub fetch_input {
  my ($self) = @_;

  my $base_path     = $self->param('base_path');
  my $out_file_stem = $self->param('out_file_stem');
  my $species       = $self->param('species');
  my $release       = $self->param('release');
  $add_xrefs        = $self->param('xrefs');

  throw "Need a species" unless $species;
  throw "Need a release" unless $release;
  throw "Need a base_path" unless $base_path;

  my $out_file;
  if (defined $out_file_stem) {
    $out_file = catdir($base_path, "$species.$out_file_stem");
  } else {
    $out_file = $self->_generate_file_name();
  }

  $self->param('out_file', $out_file);
  $self->param('out_files', [$out_file]);
  open(my $fh, '>', $out_file) or $self->throw("Cannot open file $out_file: $!");
  $self->param('out_fh', $fh);

  return;
}

sub run {
  my ($self) = @_;
  my $species          = $self->param_required('species');
  my $db_type          = $self->param_required('db_type');
  my $out_file         = $self->param_required('out_file');
  my $out_fh           = $self->param_required('out_fh');
  my $feature_types    = $self->param_required('feature_type');
  my $per_chromosome   = $self->param_required('per_chromosome');
  my $include_scaffold = $self->param_required('include_scaffold');
  my $logic_names      = $self->param_required('logic_name');
  
  my $reg = 'Bio::EnsEMBL::Registry';

#  my $sa = $reg->get_adaptor($species, $db_type, 'Slice');
#  my $slices = $sa->fetch_all('toplevel');
  
  my $oa = $reg->get_adaptor('multi', 'ontology', 'OntologyTerm');
  my $dba = $self->core_dba();

  my $mc = $dba->get_MetaContainer();
  my $provider = $mc->single_value_by_key('provider.name') || '';

  gz_work_with_file($out_fh, 'w', sub {
    my ($fh) = @_;

    my $serializer = Bio::EnsEMBL::Utils::IO::GFFSerializer->new($oa, $fh);
  
    $serializer->print_main_header(undef, $dba);

    my %adaptors;
    foreach my $feature_type (@$feature_types) {
      $adaptors{$feature_type} = $reg->get_adaptor($species, $db_type, $feature_type);
      if ($feature_type eq 'Transcript') {
        $adaptors{'Exon'} = $reg->get_adaptor($species, $db_type, 'Exon');
      }
    }

    my %chr;
    my $has_chromosome = $self->has_chromosome($dba);

    # now get all slices and filter for 1st portion of human Y
    my $slices = $self->get_Slices($self->param('db_type'), 1);
    my $count = 0;
    while (my $slice = shift @{$slices}) {
      if ($include_scaffold) {
        $slice->source($provider) if $provider;
        $serializer->print_feature($slice);
      }
      foreach my $feature_type (@$feature_types) {
$count++; last if $count > 100;
        my $features = $self->fetch_features($feature_type, $adaptors{$feature_type}, $logic_names, $slice);
        $serializer->print_feature_list($features);
  
        if ($per_chromosome && $has_chromosome) {
          my $chr_serializer = $self->chr_serializer($out_file, $oa, $slice, \%chr);
          $chr_serializer->print_feature_list($features);
        }
      }
      last;
    }

    my $out_files = $self->param('out_files');

    foreach my $slice_name (keys %chr) {
      close($chr{$slice_name}{'fh'});
      push @$out_files, $chr{$slice_name}{'file'};
    }

    $self->param('out_files', $out_files)

  });

  $self->info("Dumping GFF3 README for %s", $self->param('species'));
  $self->_create_README();
  
}

sub fetch_features {
  my ($self, $feature_type, $adaptor, $logic_names, $slice) = @_;
  
  my @features;
  if (scalar(@$logic_names) == 0) {
    @features = @{$adaptor->fetch_all_by_Slice($slice)};
  } else {
    foreach my $logic_name (@$logic_names) {
      my $features;
      if ($feature_type eq 'Transcript') {
        $features = $adaptor->fetch_all_by_Slice($slice, 0, $logic_name);
      } else {
        $features = $adaptor->fetch_all_by_Slice($slice, $logic_name);
      }
      push @features, @$features;
    }
  }
  
  if ($feature_type eq 'Transcript') {
    my $exon_features = $self->exon_features(\@features);
    push @features, @$exon_features;
  }
      
  return \@features;
}

sub exon_features {
  my ($self, $transcripts) = @_;
  
  my @cds_features;
  my @exon_features;
  my @utr_features;
  
  foreach my $transcript (@$transcripts) {
    push @cds_features, @{ $transcript->get_all_CDS(); };
    push @exon_features, @{ $transcript->get_all_ExonTranscripts() };
    push @utr_features, @{ $transcript->get_all_five_prime_UTRs()};
    push @utr_features, @{ $transcript->get_all_three_prime_UTRs()};
  }
  
  return [@exon_features, @cds_features, @utr_features];
}

sub chr_serializer {
  my ($self, $out_file, $oa, $slice, $chr) = @_;
  
  my $slice_name;
  if ($slice->karyotype_rank > 0) {
    $slice_name = 'chromosome.'.$slice->seq_region_name;
  } else {
    $slice_name = 'nonchromosomal';
  }
    
  unless (exists $$chr{$slice_name}) {
    (my $chr_file = $out_file) =~ s/([^\.]+)$/$slice_name.$1/;
    open(my $chr_fh, '>', $chr_file) or $self->throw("Cannot open file $chr_file: $!");
    
    my $chr_serializer = Bio::EnsEMBL::Utils::IO::GFFSerializer->new($oa, $chr_fh);
    $chr_serializer->print_main_header([$slice]);
    
    $$chr{$slice_name}{'fh'} = $chr_fh;
    $$chr{$slice_name}{'file'} = $chr_file;
    $$chr{$slice_name}{'serializer'} = $chr_serializer;
  }
  
  return $$chr{$slice_name}{'serializer'};
}

sub Bio::EnsEMBL::Transcript::summary_as_hash {
  my $self = shift;
  my %summary;

  my $parent_gene = $self->get_Gene();

  $summary{'seq_region_name'} = $self->seq_region_name;
  $summary{'source'}          = $parent_gene->source;
  $summary{'start'}           = $self->seq_region_start;
  $summary{'end'}             = $self->seq_region_end;
  $summary{'strand'}          = $self->strand;
  $summary{'id'}              = $self->display_id;
  $summary{'Parent'}          = $parent_gene->stable_id;
  $summary{'biotype'}         = $self->biotype;
  $summary{'version'}         = $self->version;
  $summary{'Name'}            = $self->external_name;

  # Add xrefs
  if ($add_xrefs) {
    my $xrefs = $self->get_all_xrefs();
    my (@db_xrefs, @go_xrefs);
    foreach my $xref (sort {$a->dbname cmp $b->dbname} @$xrefs) {
      my $dbname = $xref->dbname;
      if ($dbname eq 'GO') {
        push @go_xrefs, "$dbname:".$xref->display_id;
      } else {
        $dbname =~ s/^RefSeq.*/RefSeq/;
        $dbname =~ s/^Uniprot.*/UniProtKB/;
        $dbname =~ s/^protein_id.*/NCBI_GP/;
        push @db_xrefs,"$dbname:".$xref->display_id;
      }
    }
    $summary{'Dbxref'} = \@db_xrefs if scalar(@db_xrefs);
    $summary{'Ontology_term'} = \@go_xrefs if scalar(@go_xrefs);
  }

  return \%summary;
}

sub _generate_file_name {
  my ($self) = @_;

  # File name format looks like:
  # <species>.<assembly>.<release>.gff3.gz
  # e.g. Homo_sapiens.GRCh37.71.gff3.gz
  my @name_bits;
  push @name_bits, $self->web_name();
  push @name_bits, $self->assembly();
  push @name_bits, $self->param('release');
  push @name_bits, 'gff3', 'gz';

  my $file_name = join( '.', @name_bits );
  my $path = $self->data_path();

  return File::Spec->catfile($path, $file_name);

}

sub data_path {
  my ($self) = @_;

  $self->throw("No 'species' parameter specified")
    unless $self->param('species');

  return $self->get_dir('gff3', $self->param('species'));
}

sub _create_README {
  my ($self) = @_;
  my $species = $self->scientific_name();

  my $readme = <<README;
#### README ####

-----------------------
GFF FLATFILE DUMPS
-----------------------
This directory contains GFF flatfile dumps. All files are compressed
using GNU Zip.

Ensembl provides an automatic gene annotation for $species.
For some species ( human, mouse, zebrafish and pig), the
annotation provided through Ensembl also includes manual annotation
from HAVANA. In the case of human this is the GENCODE gene set.

GFF3 provides access to all annotated transcripts which make
up an Ensembl gene set. Annotation is based on alignments of
biological evidence (eg. proteins, cDNAs, RNA-seq) to a genome assembly.
The annotation dumped here is transcribed and translated from the
genome assembly and is not the original input sequence data that
we used for alignment. Therefore, the sequences provided by Ensembl
may differ from the original input sequence data where the genome
assembly is different to the aligned sequence.

GFF flat file format dumping provides all the sequence features known by 
Ensembl, including protein coding genes, ncRNA, repeat features etc. 
Annotation is based on alignments of biological evidence (eg. proteins,
cDNAs, RNA-seq) to a genome assembly. The annotation dumped here is 
transcribed and translated from the genome assembly and is not the
original input sequence data that we used for alignment. Therefore,
the sequences provided by Ensembl may differ from the original input
sequence data where the genome assembly is different to the aligned sequence.
Considerably more information is stored in Ensembl: the flat file 
just gives a representation which is compatible with existing tools.

We are considering other information that should be made dumpable. In 
general we would prefer people to use database access over flat file 
access if you want to do something serious with the data. 

Note the following features of the GFF3 format provided on this site:
1) types are described using SO terms that are as specific as possible.
e.g. protein_coding_gene is used where a gene is known to be protein coding
2) Phase is currently set to 0 - the phase used by the Ensembl system
is stored as an attribute
3) Some validators may warn about duplicated identifiers for CDS features. 
This is to allow split features to be grouped.

We are actively working to improve our GFF3 so some of these issues may
be addressed in future releases of Ensembl.

-----------
FILE NAMES
------------
The files are consistently named following this pattern:
   <species>.<assembly>.<_version>.gff3.gz

<species>:       The systematic name of the species. 
<assembly>:      The assembly build name.
<version>:       The version of Ensembl from which the data was exported.
gff3 : All files in these directories are in GFF3 format
gz : All files are compacted with GNU Zip for storage efficiency.

e.g. 
Homo_sapiens.GRCh38.81.gff3.gz

--------------------------------
Definition and supported options
--------------------------------

GFF3 files are nine-column, tab-delimited, plain text files. Literal use of tab,
newline, carriage return, the percent (%) sign, and control characters must be
encoded using RFC 3986 Percent-Encoding; no other characters may be encoded.
Backslash and other ad-hoc escaping conventions that have been added to the GFF
format are not allowed. The file contents may include any character in the set
supported by the operating environment, although for portability with other
systems, use of Latin-1 or Unicode are recommended.

Fields

Fields are tab-separated. Also, all but the final field in each feature line
must contain a valu; "empty" columns are denoted with a '.'

   seqid     - The ID of the landmark used to establish the coordinate system for the current
               feature. IDs may contain any characters, but must escape any characters not in
               the set [a-zA-Z0-9.:^*$@!+_?-|]. In particular, IDs may not contain unescaped
               whitespace and must not begin with an unescaped ">".
   source    - The source is a free text qualifier intended to describe the algorithm or
               operating procedure that generated this feature. Typically this is the name of a
               piece of software, such as "Genescan" or a database name, such as "Genbank." In
               effect, the source is used to extend the feature ontology by adding a qualifier
               to the type creating a new composite type that is a subclass of the type in the
               type column.
   type      - The type of the feature (previously called the "method"). This is constrained to
               be either: (a)a term from the "lite" version of the Sequence Ontology - SOFA, a
               term from the full Sequence Ontology - it must be an is_a child of
               sequence_feature (SO:0000110) or (c) a SOFA or SO accession number. The latter
               alternative is distinguished using the syntax SO:000000.
   start     - start position of the feature in positive 1-based integer coordinates
               always less than or equal to end
   end       - end position of the feature in positive 1-based integer coordinates
   score     - The score of the feature, a floating point number. As in earlier versions of the
               format, the semantics of the score are ill-defined. It is strongly recommended
               that E-values be used for sequence similarity features, and that P-values be
               used for ab initio gene prediction features.
   strand    - The strand of the feature. + for positive strand (relative to the landmark), -
               for minus strand, and . for features that are not stranded. In addition, ? can
               be used for features whose strandedness is relevant, but unknown.
   phase     - For features of type "CDS", the phase indicates where the feature begins with
               reference to the reading frame. The phase is one of the integers 0, 1, or 2,
               indicating the number of bases that should be removed from the beginning of this
               feature to reach the first base of the next codon. In other words, a phase of
               "0" indicates that the next codon begins at the first base of the region
               described by the current line, a phase of "1" indicates that the next codon
               begins at the second base of this region, and a phase of "2" indicates that the
               codon begins at the third base of this region. This is NOT to be confused with
               the frame, which is simply start modulo 3.
   attribute - A list of feature attributes in the format tag=value. Multiple tag=value pairs
               are separated by semicolons. URL escaping rules are used for tags or values
               containing the following characters: ",=;". Spaces are allowed in this field,
               but tabs must be replaced with the %09 URL escape. Attribute values do not need
               to be and should not be quoted. The quotes should be included as part of the
               value by parsers and not stripped.


Attributes

The following attributes are available. All attributes are semi-colon separated
pairs of keys and values.

- ID:     ID of the feature. IDs for each feature must be unique within the
          scope of the GFF file. In the case of discontinuous features (i.e. a single
          feature that exists over multiple genomic locations) the same ID may appear on
          multiple lines. All lines that share an ID collectively represent a single
          feature.
- Name:   Display name for the feature. This is the name to be displayed to the user.
- Alias:  A secondary name for the feature
- Parent: Indicates the parent of the feature. A parent ID can be used to group exons into
          transcripts, transcripts into genes, and so forth
- Dbxref: A database cross reference
- Ontology_term: A cross reference to an ontology term
- Is_circular:   A flag to indicate whether a feature is circular

Pragmas/Metadata

GFF3 files can contain meta-data. In the case of experimental meta-data these are
noted by a #!. Those which are stable are noted by a ##. Meta data is a single key,
a space and then the value. Current meta data keys are:

* genome-build -  Build identifier of the assembly e.g. GRCh37.p11
* genome-version - Version of this assembly e.g. GRCh37
* genome-date - The date of this assembly's release e.g. 2009-02
* genome-build-accession - The accession and source of this accession e.g. NCBI:GCA_000001405.14
* genebuild-last-updated - The date of the last genebuild update e.g. 2013-09

------------------
Example GFF3 output
------------------

##gff-version 3
#!genome-build  Pmarinus_7.0
#!genome-version Pmarinus_7.0
#!genome-date 2011-01
#!genebuild-last-updated 2013-04

GL476399        Pmarinus_7.0    supercontig     1       4695893 .       .       .       ID=supercontig:GL476399;Alias=scaffold_71
GL476399        ensembl gene    2596494 2601138 .       +       .       ID=gene:ENSPMAG00000009070;Name=TRYPA3;biotype=protein_coding;description=Trypsinogen A1%3B Trypsinogen a3%3B Uncharacterized protein  [Source:UniProtKB/TrEMBL%3BAcc:O42608];logic_name=ensembl;version=1
GL476399        ensembl transcript      2596494 2601138 .       +       .       ID=transcript:ENSPMAT00000010026;Name=TRYPA3-201;Parent=gene:ENSPMAG00000009070;biotype=protein_coding;version=1
GL476399        ensembl exon    2596494 2596538 .       +       .       Name=ENSPMAE00000087923;Parent=transcript:ENSPMAT00000010026;constitutive=1;ensembl_end_phase=1;ensembl_phase=-1;rank=1;version=1
GL476399        ensembl exon    2598202 2598361 .       +       .       Name=ENSPMAE00000087929;Parent=transcript:ENSPMAT00000010026;constitutive=1;ensembl_end_phase=2;ensembl_phase=1;rank=2;version=1
GL476399        ensembl exon    2599023 2599282 .       +       .       Name=ENSPMAE00000087937;Parent=transcript:ENSPMAT00000010026;constitutive=1;ensembl_end_phase=1;ensembl_phase=2;rank=3;version=1
GL476399        ensembl exon    2599814 2599947 .       +       .       Name=ENSPMAE00000087952;Parent=transcript:ENSPMAT00000010026;constitutive=1;ensembl_end_phase=0;ensembl_phase=1;rank=4;version=1
GL476399        ensembl exon    2600895 2601138 .       +       .       Name=ENSPMAE00000087966;Parent=transcript:ENSPMAT00000010026;constitutive=1;ensembl_end_phase=-1;ensembl_phase=0;rank=5;version=1
GL476399        ensembl CDS     2596499 2596538 .       +       0       ID=CDS:ENSPMAP00000009982;Parent=transcript:ENSPMAT00000010026
GL476399        ensembl CDS     2598202 2598361 .       +       2       ID=CDS:ENSPMAP00000009982;Parent=transcript:ENSPMAT00000010026
GL476399        ensembl CDS     2599023 2599282 .       +       1       ID=CDS:ENSPMAP00000009982;Parent=transcript:ENSPMAT00000010026
GL476399        ensembl CDS     2599814 2599947 .       +       2       ID=CDS:ENSPMAP00000009982;Parent=transcript:ENSPMAT00000010026
GL476399        ensembl CDS     2600895 2601044 .       +       0       ID=CDS:ENSPMAP00000009982;Parent=transcript:ENSPMAT00000010026
GL476399        ensembl five_prime_UTR  2596494 2596498 .       +       .       Parent=transcript:ENSPMAT00000010026
GL476399        ensembl three_prime_UTR 2601045 2601138 .       +       .       Parent=transcript:ENSPMAT00000010026

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


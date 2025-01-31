=head1 LICENSE
Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2020] EMBL-European Bioinformatics Institute
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
     http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=head1 NAME
Bio::EnsEMBL::Production::Pipeline::StableID::EmailReport

=head1 DESCRIPTION
Send an email with details of any non-unique stable IDs.

=cut

package Bio::EnsEMBL::Production::Pipeline::StableID::EmailReport;

use strict;
use warnings;
use feature 'say';

use base ('Bio::EnsEMBL::Hive::RunnableDB::NotifyByEmail');

use File::Spec::Functions qw(catdir);
use Path::Tiny;

sub fetch_input {
  my ($self) = @_;

  my $pipeline_name = $self->param('pipeline_name');
  my $output_dir    = $self->param('output_dir');
  my $output_file   = catdir($output_dir, "$pipeline_name.txt");

  my $duplicates = $self->find_duplicates($output_file);

  my $subject = "Stable ID pipeline completed ($pipeline_name)";
  $self->param('subject', $subject);

  my $text =
    "The $pipeline_name pipeline has completed successfully.\n\n".
    "There are $duplicates duplicated stable IDs. ".
    "Details: $output_file";

  $self->param('text', $text);
}

sub find_duplicates {
  my ($self, $output_file) = @_;

  my $duplicates = 0;

  my $dbh = $self->data_dbc->db_handle;
  my $sql = qq/
    SELECT
      stable_id, db_type, object_type,
      COUNT(species_id) AS species_count,
      GROUP_CONCAT(name) AS species_name_list
    FROM
      stable_id_lookup INNER JOIN
      species USING (species_id)
    GROUP BY
      stable_id, db_type, object_type
    HAVING
      species_count > 1
  /;
  my $sth = $dbh->prepare($sql) or die $dbh->errstr();
  $sth->execute();

  my $out = path($output_file);
  $out->remove if -e $output_file;

  while (my @row = $sth->fetchrow_array) {
    $out->append_raw(join("\t",@row)."\n");
    $duplicates++;
  }

  return $duplicates;
}

1;

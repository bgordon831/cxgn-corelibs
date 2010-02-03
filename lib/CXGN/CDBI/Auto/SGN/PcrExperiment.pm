package CXGN::CDBI::Auto::SGN::PcrExperiment;
# This class is autogenerated by cdbigen.pl.  Any modification
# by you will be fruitless.

=head1 DESCRIPTION

CXGN::CDBI::Auto::SGN::PcrExperiment - object abstraction for rows in the sgn.pcr_experiment table.

Autogenerated by cdbigen.pl.

=head1 DATA FIELDS

  Primary Keys:
      pcr_experiment_id

  Columns:
      pcr_experiment_id
      marker_id
      mg_concentration
      annealing_temp
      primer_id_fwd
      primer_id_rev
      subscript
      experiment_type_id
      map_id
      additional_enzymes
      primer_type
      predicted
      primer_id_pd
      accession_id

  Sequence:
      none

=cut

use base 'CXGN::CDBI::Class::DBI';
__PACKAGE__->table( 'sgn.pcr_experiment' );

our @primary_key_names =
    qw/
      pcr_experiment_id
      /;

our @column_names =
    qw/
      pcr_experiment_id
      marker_id
      mg_concentration
      annealing_temp
      primer_id_fwd
      primer_id_rev
      subscript
      experiment_type_id
      map_id
      additional_enzymes
      primer_type
      predicted
      primer_id_pd
      accession_id
      /;

__PACKAGE__->columns( Primary => @primary_key_names, );
__PACKAGE__->columns( All     => @column_names,      );


=head1 AUTHOR

cdbigen.pl

=cut

###
1;#do not remove
###

#
# You may distribute this module under the same terms as perl itself
#
# POD documentation - main docs before the code

=pod 

=head1 NAME

Bio::EnsEMBL::Compara::RunnableDB::GeneStoreNCMembers

=cut

=head1 SYNOPSIS

my $db      = Bio::EnsEMBL::Compara::DBAdaptor->new($locator);
my $g_load_members = Bio::EnsEMBL::Compara::RunnableDB::GeneStoreNCMembers->new (
                                                    -db      => $db,
                                                    -input_id   => $input_id
                                                    -analysis   => $analysis );
$g_load_members->fetch_input(); #reads from DB
$g_load_members->run();
$g_load_members->output();
$g_load_members->write_output(); #writes to DB

=cut

=head1 DESCRIPTION

Create members from a given ncRNA gene (both ncRNA members and gene member).

=cut

=head1 CONTACT

Describe contact details here

=cut

=head1 APPENDIX

The rest of the documentation details each of the object methods.
Internal methods are usually preceded with a _

=cut

package Bio::EnsEMBL::Compara::RunnableDB::GeneStoreNCMembers;

use strict;
use Bio::EnsEMBL::Compara::Member;
use Bio::EnsEMBL::Compara::Subset;

use base ('Bio::EnsEMBL::Compara::RunnableDB::BaseRunnable');

sub param_defaults {
    return {
        'store_genes'  => 1,    # whether genes are also stored as members
    };
}

=head2 fetch_input

    Title   :   fetch_input
    Usage   :   $self->fetch_input
    Function:   prepares global variables and DB connections
    Returns :   none
    Args    :   none

=cut

sub fetch_input {
    my $self = shift @_;

    $self->input_job->transient_error(0);
    my $genome_db_id = $self->param('genome_db_id') || die "'genome_db_id' parameter is an obligatory one, please specify";
    my $stable_id = $self->param('stable_id')       || die "'stable_id' parameter is an obligatory one, please specify";
    $self->input_job->transient_error(1);

        # fetch the Compara::GenomeDB object for the genome_db_id
    my $genome_db = $self->compara_dba->get_GenomeDBAdaptor->fetch_by_dbID($genome_db_id) or die "Could not fetch genome_db with id=$genome_db_id";
    $self->param('genome_db', $genome_db);
  
        # using genome_db_id connect to external core database
    my $core_db = $genome_db->db_adaptor() or die "Can't connect to genome database for id=$genome_db_id";
    $self->param('core_db', $core_db);
  
        # connect to the subsets in order to start adding to them:
    my $subset_adaptor = $self->compara_dba->get_SubsetAdaptor;

    my $ncrna_subset_id = $self->param('ncrna_subset_id');
    my $gene_subset_id  = $self->param('gene_subset_id');

    my $ncrna_subset = $subset_adaptor->fetch_by_dbID($ncrna_subset_id) or die "Could not fetch subset for id=$ncrna_subset_id";
    my $gene_subset  = $subset_adaptor->fetch_by_dbID($gene_subset_id)  or die "Could not fetch subset for id=$gene_subset_id";

    $self->param('ncrna_subset', $ncrna_subset);
    $self->param('gene_subset',  $gene_subset);
}


sub run {
    my $self = shift @_;

    my $core_db     = $self->param('core_db');
    my $stable_id   = $self->param('stable_id');

    $self->compara_dba->dbc->disconnect_when_inactive(0);
    $core_db->dbc->disconnect_when_inactive(0);

    my $gene_adaptor = $core_db->get_GeneAdaptor or die "Could not create the core GeneAdaptor";

    my $gene = $gene_adaptor->fetch_by_stable_id( $stable_id ) or die "Could not fetch gene with stable_id '$stable_id'";

        # Store gene:
    $self->store_ncrna_gene($gene);

    $self->compara_dba->dbc->disconnect_when_inactive(1);
    $core_db->dbc->disconnect_when_inactive(1);
}

sub write_output {
    my $self = shift @_;

}


######################################
#
# subroutines
#
#####################################


sub store_ncrna_gene {
  my $self = shift;
  my $gene = shift;

  my $longest_ncrna_member;
  my $max_ncrna_length = 0;
  my $gene_member;
  my $gene_member_not_stored = 1;

    my $member_adaptor = $self->compara_dba->get_MemberAdaptor();

    my $pseudo_stableID_prefix = $self->param('pseudo_stableID_prefix');

    if($pseudo_stableID_prefix) {
        $gene->stable_id($pseudo_stableID_prefix ."G_". $gene->dbID);
    }

  foreach my $transcript (@{$gene->get_all_Transcripts}) {
    if (defined $transcript->translation) {
      warn("Translation exists for ncRNA transcript ", $transcript->stable_id, "(dbID=",$transcript->dbID.")\n");
      next;
    }

    if($pseudo_stableID_prefix) {
        $transcript->stable_id($pseudo_stableID_prefix ."T_". $transcript->dbID);
    }

    #print("gene " . $gene->stable_id . "\n");
    print("     transcript " . $transcript->stable_id ) if($self->debug);

    my $ncrna_member = Bio::EnsEMBL::Compara::Member->new_from_transcript(
         -transcript  => $transcript,
         -genome_db   => $self->param('genome_db'),
         -translate   => 'ncrna',
         -description => $self->fasta_description($gene, $transcript),
   );

    print(" => member " . $ncrna_member->stable_id) if($self->debug);

    my $transcript_spliced_seq = $transcript->spliced_seq;

    # store gene_member here only if at least one peptide is to be loaded for
    # the gene.
    if($self->param('store_genes') and $gene_member_not_stored) {
      print("     gene       " . $gene->stable_id ) if($self->debug);
      $gene_member = Bio::EnsEMBL::Compara::Member->new_from_gene(
          -gene      => $gene,
          -genome_db => $self->param('genome_db'),
      );
      print(" => member " . $gene_member->stable_id) if($self->debug);

      eval {
        $member_adaptor->store($gene_member);
        print(" : stored") if($self->debug);
      };

      $self->param('gene_subset')->add_member($gene_member);
      print("\n") if($self->debug);
      $gene_member_not_stored = 0;
    }

    $member_adaptor->store($ncrna_member);
    $member_adaptor->store_gene_peptide_link($gene_member->dbID, $ncrna_member->dbID);
    print(" : stored\n") if($self->debug);

    if(length($transcript_spliced_seq) > $max_ncrna_length) {
      $max_ncrna_length     = length($transcript_spliced_seq);
      $longest_ncrna_member = $ncrna_member;
    }

  }

  if($longest_ncrna_member) {
    $self->param('ncrna_subset')->add_member( $longest_ncrna_member );
  }
}

sub fasta_description {
  my ($self, $gene, $transcript) = @_;
  my $acc = 'NULL'; my $biotype = undef;
  $DB::single=1;1;
  eval { $acc = $transcript->display_xref->primary_id;};
  unless ($acc =~ /RF00/) {
    $biotype = $transcript->biotype;
    if ($biotype =~ /miRNA/) {
      my @exons = @{$transcript->get_all_Exons};
      $self->throw("unexpected miRNA with more than one exon") if (1 < scalar @exons);
      my $exon = $exons[0];
      my @supporting_features = @{$exon->get_all_supporting_features};
      if (1 < scalar @supporting_features || 0 == scalar @supporting_features) {
        warn("unexpected miRNA supporting features");
        next;
      }
      my $supporting_feature = $supporting_features[0];
      eval { $acc = $supporting_feature->hseqname; };
    } elsif ($biotype =~ /snoRNA/) {
      eval { $acc = $transcript->external_name; };
      #     } elsif ($biotype =~ /Mt_tRNA/) { # wont deal with these at the moment
      #       $acc = 'RF00005';
    } elsif ($biotype =~ /Mt_rRNA/) {
      # $acc = $biotype;
    } else {
      # We just leave it as NULL and will skip it in RFAMClassify
    }
  }
  my $description = "Transcript:" . $transcript->stable_id .
                    " Gene:" .      $gene->stable_id .
                    " Chr:" .       $gene->seq_region_name .
                    " Start:" .     $gene->seq_region_start .
                    " End:" .       $gene->seq_region_end.
                    " Acc:" .       $acc;
  print STDERR "Description... $description\n" if ($self->debug);
  return $description;
}

1;

package Cfn::Colored::Diff {
  use Moose;

  our $VERSION = '0.01';
  #ABSTRACT: Show differences between two cloudformation files

  with 'MooseX::Getopt';
  use Cfn;
  use Cfn::Diff;
  use File::Slurp;
  use String::Diff;
  use Term::ANSIColor qw/:constants/;
  use Scalar::Util;

  has left => (
    is            => 'rw',
    isa           => 'Str',
    documentation => q[cfn:<REGION>:<NAME>|file:<JSON_FILE>],
    required      => 1,
  );

  has right => (
    is            => 'rw',
    isa           => 'Str',
    documentation => q[cfn:<REGION>:<NAME>|file:<JSON_FILE>],
    required      => 1,
  );

  has pretty => (
    is            => 'ro',
    isa           => 'Bool',
    documentation => 'Pretty print the changes in JSON',
    default       => 1
  );

  has _left_cfn => (
    is => 'ro',
    isa => 'Cfn',
    lazy => 1,
    default => sub { shift->_get_cfn('left') }
  );

  has _right_cfn => (
    is => 'ro',
    isa => 'Cfn',
    lazy => 1,
    default => sub { shift->_get_cfn('right') }
  );

  sub _get_cfn {
    my ($self, $side) = @_;
    if (my ($region, $stack_name) = ($self->$side =~ m/^cfn\:(.*?)\:(.*)$/)) {
      require Paws;
      return Cfn->from_json(Paws->service('CloudFormation', region => $region)->GetTemplate(StackName => $stack_name, TemplateStage => 'Original')->TemplateBody);
    } elsif (-e $self->$side) {
      require File::Slurp;
      # read_file needs to be in scalar context to return all lines as one string
      return Cfn->from_json(scalar(File::Slurp::read_file($self->$side)));
    } else {
      die "Unknown format for side $side";
    }
  }

  sub _is_dynamic {
    my ($self, $element) = @_;
    return (blessed($element) and $element->isa('CCfnX::DynamicValue'));
  }

  sub run {
    my $self = shift;

    printf "Comparing %s to %s\n", $self->left, $self->right;

    my $differences = Cfn::Diff->new(left => $self->_left_cfn, right => $self->_right_cfn);

    if (@{ $differences->changes } == 0) {
      print "No changes detected\n";
      return;
    }

    my @incompats = grep { $_->isa('Cfn::Diff::IncompatibleChange') } @{ $differences->changes };

    if (@incompats) {
      foreach my $change (@incompats) {
        printf "\t    to: %s%s%s\n", RED . DARK . BOLD, 'Property ' . $change->path . ' has a type change from ' . $change->from . ' to ' . $change->to, CLEAR;
      }
      # Don't want to analyze anymore changes...
      return;
    }

    foreach my $change (@{ $differences->changes }) {
      my $compare_from = $change->from;
      my $compare_to   = $change->to;

      # We'll always compare the textual form that cloudformation would recieve, since the diff will return
      # changes in properties that have DynamicValues in them, that can render the result equal or different

      $compare_from = $self->_print_element($change->from, $self->_left_cfn);
      $compare_to   = $self->_print_element($change->to, $self->_right_cfn);

      printf "%s %s\n", $change->path, $change->change;
      if ($change->isa('Cfn::Diff::ResourcePropertyChange')) {
        my $mutability = $change->mutability;
        if (not defined $mutability) {
          printf "%s%s%s\n", YELLOW . DARK . BOLD, 'No information on replacement of Resource', CLEAR;
        } elsif ($mutability eq 'Mutable') {
          printf "\teffect: %s%s%s\n", GREEN . DARK . BOLD, 'Property change will not cause replacement', CLEAR;
        } elsif ($mutability eq 'Immutable') {
          printf "\teffect: %s%s%s\n", RED . DARK . BOLD, 'Property change will cause replacement', CLEAR;
        } elsif ($mutability eq 'Conditional') {
          printf "\teffect: %s%s%s\n", YELLOW . DARK . BOLD, 'Property change will MAYBE cause replacement', CLEAR;
        } else {
          die "Unrecognized attribute mutability: $mutability";
        }
      }
      if (defined $compare_from and defined $compare_to and $compare_from ne $compare_to) {
        my $diff = String::Diff::diff($compare_from, $compare_to,
          remove_open => RED . DARK . BOLD,
          remove_close => CLEAR,
          append_open => GREEN . DARK . BOLD,
          append_close => CLEAR,
        );
        printf "\t  from: %s\n", $diff->[0];
        printf "\t    to: %s\n", $diff->[1];
      } elsif (not defined $compare_from) {
        printf "\t  from:\n";
        printf "\t    to: %s%s%s\n", GREEN . DARK . BOLD, $compare_to, CLEAR;
      } elsif (not defined $compare_to) {
        printf "\t  from: %s%s%s\n", RED . DARK . BOLD, $compare_from, CLEAR;
        printf "\t    to:\n";
      }
      printf "----------------------\n";
    }
  }

  sub _print_element {
    my ($self, $element, $c) = @_;

    if (blessed($element)) {
      if ($element->isa('Cfn::Value::Primitive')){
        return $element->Value;
      } elsif ($element->isa('CCfnX::DynamicValue')) {
        # A dynamic value has to be converted to a normal value, and then be "printed"
        return $self->_print_element($element->to_value($c), $c);
      } else {
        if ($self->pretty) {
          return JSON->new->canonical->pretty->encode($element->as_hashref($c));
        } else {
          return JSON->new->canonical->encode($element->as_hashref($c));
        }
      }
    } else {
      if (ref($element) eq 'HASH') {
        my %jsondocs;

        foreach my $key (keys(%{$element})) {
          my $value = $self->_print_element($element->{$key});

          if ($value =~ /^\{/) {
            $jsondocs{$key} = JSON->new->decode($value);
          }
          else {
            $jsondocs{$key} = $value;
          }
        }

        if ($self->pretty) {
          return JSON->new->canonical->pretty->encode(\%jsondocs);
        } else {
          return JSON->new->canonical->encode(\%jsondocs);
        }
      }
      else {
        return $element;
      }
    }
  }
}

1;

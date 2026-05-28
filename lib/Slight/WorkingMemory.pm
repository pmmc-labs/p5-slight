use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

class Slight::WorkingMemory {
    field $alloc :param :reader;

    field %facts;
    field %forward;
    field %reverse;

    my method index_fact ($fact) {
        my ($s, $p, $o) = $fact->uncons;
        (($forward{ $s->hash } //= +{})
                ->{ $p->hash } //= +{})
                ->{ $o->hash }
                    = (($reverse{ $o->hash } //= +{})
                        ->{ $p->hash } //= +{})
                        ->{ $s->hash }
                            = $fact;
    }

    method contains_hash  ($hash) { exists $facts{$hash} }
    method lookup_by_hash ($hash) { return $facts{$hash} }

    method retract ($hash) { delete $facts{$hash} }

    method assert (@args) {
        my $fact;
        if (scalar @args == 3) {
            $fact = $alloc->List( @args );
        } elsif (scalar @args == 1) {
            $fact = shift @args;
        } else {
            die "WTF IS THIS! ", join ', ' => @args;
        }
        $facts{ $fact->hash } //= $self->&index_fact( $fact );
    }

    method query ($s, $p, $o) {
        # s p o
        if (defined $s && defined $p && defined $o) {
            return $forward{ $s->hash }->{ $p->hash }->{ $o->hash };
        }
        # s p _
        elsif (defined $s && defined $p && not(defined $o)) {
            return values $forward{ $s->hash }->{ $p->hash }->%*;
        }
        # s _ o
        elsif (defined $s && not(defined $p) && defined $o) {
            return map  { $forward{ $s->hash }->{ $_ }->{ $o->hash } }
                   grep { exists $reverse{ $o->hash } && exists $reverse{ $o->hash }->{ $_ } }
                   keys $forward{ $s->hash }->%*;
        }
        # _ p o
        elsif (not(defined $s) && defined $p && defined $o) {
            return values $reverse{ $o->hash }->{ $p->hash }->%*;
        }
        # s _ _
        elsif (defined $s && not(defined $p) && not(defined $o)) {
            return map {
                    my $_p = $_;
                    map {
                        $forward{ $s->hash }->{$_p}->{$_}
                    } keys $forward{ $s->hash }->{$_p}->%*
                } keys $forward{ $s->hash }->%*;
        }
        # _ _ o
        elsif (not(defined $s) && not(defined $p) && defined $o) {
            return map {
                    my $_p = $_;
                    map {
                        $reverse{ $o->hash }->{$_p}->{$_}
                    } keys $reverse{ $o->hash }->{$_p}->%*
                } keys $reverse{ $o->hash }->%*;
        }
        # _ p _
        elsif (not(defined $s) && defined $p && not(defined $o)) {
            return map {
                exists $forward{ $_ }->{ $p->hash }
                    ? values $forward{ $_ }->{ $p->hash }->%*
                    : ()
            } keys %forward;
        }
        else {
            die "You must specify at least two parameters";
        }
    }
}

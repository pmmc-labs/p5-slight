use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

class Slight::TripleStore {
    field $alloc :param :reader;

    field %triples;
    field %findex;
    field %rindex;

    my method index_triple ($triple) {
        my ($s, $p, $o) = ($triple->subject,
                           $triple->predicate,
                           $triple->object);
        (($findex{ $s->hash } //= +{})
              ->{ $p->hash } //= +{})
              ->{ $o->hash }
                = (($rindex{ $o->hash } //= +{})
                    ->{ $p->hash } //= +{})
                    ->{ $s->hash }
                        = $triple;
    }

    method insert (@args) {
        my $triple;
        if (scalar @args == 3) {
            $triple = $alloc->Triple( @args );
        } else {
            $triple = shift @args;
        }
        $triples{ $triple->hash } //= $self->&index_triple( $triple );
    }

    method contains ($hash) { exists $triples{$hash} }
    method lookup   ($hash) { return $triples{$hash} }

    method query ($s, $p, $o) {
        # s p o
        if (defined $s && defined $p && defined $o) {
            return $findex{ $s->hash }->{ $p->hash }->{ $o->hash };
        }
        # s p _
        elsif (defined $s && defined $p && not(defined $o)) {
            return values $findex{ $s->hash }->{ $p->hash }->%*;
        }
        # s _ o
        elsif (defined $s && not(defined $p) && defined $o) {
            return map  { $findex{ $s->hash }->{ $_ }->{ $o->hash } }
                   grep { exists $rindex{ $o->hash } && exists $rindex{ $o->hash }->{ $_ } }
                   keys $findex{ $s->hash }->%*;
        }
        # _ p o
        elsif (not(defined $s) && defined $p && defined $o) {
            return values $rindex{ $o->hash }->{ $p->hash }->%*;
        }
        # s _ _
        elsif (defined $s && not(defined $p) && not(defined $o)) {
            return map {
                    my $_p = $_;
                    map {
                        $findex{ $s->hash }->{$_p}->{$_}
                    } keys $findex{ $s->hash }->{$_p}->%*
                } keys $findex{ $s->hash }->%*;
        }
        # _ _ o
        elsif (not(defined $s) && not(defined $p) && defined $o) {
            return map {
                    my $_p = $_;
                    map {
                        $rindex{ $o->hash }->{$_p}->{$_}
                    } keys $rindex{ $o->hash }->{$_p}->%*
                } keys $rindex{ $o->hash }->%*;
        }
        # _ p _
        elsif (not(defined $s) && defined $p && not(defined $o)) {
            return map {
                exists $findex{ $_ }->{ $p->hash }
                    ? values $findex{ $_ }->{ $p->hash }->%*
                    : ()
            } keys %findex;
        }
        else {
            die "You must specify at least two parameters";
        }
    }
}

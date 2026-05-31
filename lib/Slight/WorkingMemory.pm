use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

class Slight::WorkingMemory {
    field $alloc :param :reader;

    field %facts;
    field %forward;
    field %reverse;

    my method index_fact ($s, $p, $o, $fact) {
        # XXX: consider adding all of these?
        # (SPO, SOP, PSO, POS, OPS, OSP)
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

    method assert ($s, $p, $o) {
        my $fact = $alloc->Triple( $s, $p, $o );
        $facts{ $fact->hash } //= $self->&index_fact( $s, $p, $o, $fact );
    }

    method retract ($s, $p, $o) {
        return false unless exists $forward{ $s->hash }->{ $p->hash }->{ $o->hash };
        my $fact = delete $forward{ $s->hash }->{ $p->hash }->{ $o->hash };
        delete $reverse{ $o->hash }->{ $p->hash }->{ $s->hash };
        delete $facts{ $fact->hash };
        return true;
    }

    method HOLE { return $alloc->Tag(':_') }

    my sub is_HOLE ($x) { $x isa Slight::Term::Tag && $x->raw eq ':_' }
    my sub is_TERM ($x) { not(is_HOLE($x)) }

    method query ($s, $p, $o) {
        # s p o
        if (is_TERM($s) && is_TERM($p) && is_TERM($o)) {
            return $forward{ $s->hash }->{ $p->hash }->{ $o->hash };
        }
        # s p :_
        elsif (is_TERM($s) && is_TERM($p) && is_HOLE($o)) {
            return values $forward{ $s->hash }->{ $p->hash }->%*;
        }
        # s :_ o
        elsif (is_TERM($s) && is_HOLE($p) && is_TERM($o)) {
            return map  { $forward{ $s->hash }->{ $_ }->{ $o->hash } }
                   grep { exists $reverse{ $o->hash } && exists $reverse{ $o->hash }->{ $_ } }
                   keys $forward{ $s->hash }->%*;
        }
        # :_ p o
        elsif (is_HOLE($s) && is_TERM($p) && is_TERM($o)) {
            return values $reverse{ $o->hash }->{ $p->hash }->%*;
        }
        # s :_ :_
        elsif (is_TERM($s) && is_HOLE($p) && is_HOLE($o)) {
            return map {
                my $_p = $_;
                map {
                    $forward{ $s->hash }->{$_p}->{$_}
                } keys $forward{ $s->hash }->{$_p}->%*
            } keys $forward{ $s->hash }->%*;
        }
        # :_ :_ o
        elsif (is_HOLE($s) && is_HOLE($p) && is_TERM($o)) {
            return map {
                my $_p = $_;
                map {
                    $reverse{ $o->hash }->{$_p}->{$_}
                } keys $reverse{ $o->hash }->{$_p}->%*
            } keys $reverse{ $o->hash }->%*;
        }
        # :_ p :_
        elsif (is_HOLE($s) && is_TERM($p) && is_HOLE($o)) {
            return map {
                exists $forward{ $_ }->{ $p->hash }
                    ? values $forward{ $_ }->{ $p->hash }->%*
                    : ()
            } keys %forward;
        }
        else {
            die "You must specify at one parameter";
        }
    }
}

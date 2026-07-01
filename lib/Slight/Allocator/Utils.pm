use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

class Allocator::Utils {
    field $alloc :param :reader;

    ## ... environs

    method CaptureClosure ($partial, $env) {
        return $alloc->Lambda(
            $self->First($partial),  # params
            $self->Second($partial), # body
            $env,                    # captured-env
            $partial->has_name       # name?
                ? $alloc->Util->Third($partial)
                : ()
        )
    }

    method InitEnv (@bindings) {
        my $env = $alloc->Nil;
        foreach my ($sym, $val) (@bindings) {
            $env = $alloc->Env( $alloc->Binding( $sym, $val ), $env );
        }
        return $env;
    }

    method Lookup ($sym, $env) {
        return undef if $env->is_nil;
        # XXX - this is a hot path and will need
        # some optimizations to speed it up
        my $candidate = $self->First($env);
        if ($self->First($candidate)->equal_to($sym)) {
            return $self->Second($candidate);
        } else {
            return $self->Lookup($sym, $self->Second($env));
        }
    }

    method BindSymbol ($sym, $val, $env) {
        $alloc->Env( $alloc->Binding( $sym, $val ), $env )
    }

    method BindParams ($params, $args, $env) {
        my @params = $alloc->Util->Uncons($params);
        my @args   = $alloc->Util->Uncons($args);
        die sprintf 'Arity mismatch, got(%s) expected(%s)' => (scalar @args), (scalar @params)
            unless scalar @args == scalar @params;
        my $local = $env;
        while (@params) {
            $local = $self->BindSymbol( shift @params, shift @args, $local )
        }
        return $local;
    }

    ## ... accessors

    method First  ($t) { $alloc->deref_index($t->data->[0]) }
    method Second ($t) { $alloc->deref_index($t->data->[1]) }
    method Third  ($t) { $alloc->deref_index($t->data->[2]) }
    method Fourth ($t) { $alloc->deref_index($t->data->[3]) }

    method Head   ($l) { $alloc->deref_index($l->data->[0]) }
    method Tail   ($l) { $alloc->deref_index($l->data->[1]) }

    ## ... lists

    method ListOf (@list) {
        my $list = $alloc->Nil;
        while (@list) {
            $list = $alloc->Cons( pop @list, $list );
        }
        return $list;
    }

    method Uncons ($list) {
        my @list;
        until ($list->is_nil) {
            push @list => $self->Head( $list );
            $list = $self->Tail( $list );
        }
        return @list;
    }

    method Reverse ($list) {
        return $self->ListOf( reverse $self->Uncons( $list ) )
    }

    method Append ($lhs, $rhs) {
        $self->ListOf( $self->Uncons( $lhs ), $self->Uncons( $rhs ) )
    }

    ## ... printing and debugging

    method pprint ($t) {
        given (blessed $t) {
            when ('Sym')     { $t->ident }
            when ('Str')     { $t->value }
            when ('Num')     { $t->value }
            when ('Bool')    { $t->data->[0] }
            when ('Nil')     { '()' }
            when ('Cons')    { sprintf '(%s)' => join ' ' => map $self->pprint($_), $alloc->Util->Uncons($t) }
            when ('Pair')    { sprintf '(%s . %s)' => $self->pprint($self->First($t)), $self->pprint($self->Second($t)) }
            when ('Env')     { sprintf '{ %s }' => join ' ' => map $self->pprint($_), $alloc->Util->Uncons($t) }
            when ('Builtin') { sprintf '<%s>' => $self->pprint($self->First($t)) }
            when ('Binding') { sprintf '(%s := %s)' => $self->pprint($self->First($t)), $self->pprint($self->Second($t)) }
            when ('Partial')  {
                sprintf '[<lambda> %s %s]' =>
                    $self->pprint($self->First($t)),
                    $self->pprint($self->Second($t))
            }
            when ('Lambda')  {
                sprintf '(<lambda> %s %s)' =>
                    $self->pprint($self->First($t)),
                    $self->pprint($self->Second($t))
            }
            when ('Condition') {
                sprintf '(<if> %s %s %s)' =>
                    $self->pprint($self->First($t)),
                    $self->pprint($self->Second($t)),
                    $self->pprint($self->Third($t))
            }
            default { die "WTF! $self" }
        }
    }

    method DUMP ($t) {
        sprintf(
            '$(%05d) | %-9s | %s | %-35s | %s',
            $t->index->idx,
            (blessed $t),
            $t->short_hash,
            (join ' ' => map {
                blessed $_
                    ? (sprintf '$(%05d)' => $_->idx)
                    : (length $_ > 33 ? (substr($_, 0, 33).' ...') : $_)
            } $t->data->@*),
            ($Slight::TERM_WIDTH > 70 ? substr($self->pprint($t), 0, ($Slight::TERM_WIDTH - 73)) : '')
        )
    }
}

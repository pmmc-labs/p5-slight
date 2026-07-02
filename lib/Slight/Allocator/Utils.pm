use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

class Allocator::Utils {
    field $alloc :param :reader;

    ## ... environs

    method InitEnv (@bindings) {
        my $env = $alloc->Nil;
        foreach my ($sym, $val) (@bindings) {
            $env = $alloc->Env( $alloc->Binding( $sym, $val ), $env );
        }
        return $env;
    }

    method Lookup ($sym, $env) {
        until ($env->is_nil) {
            my $binding = $alloc->deref_index($env->data->[0]);
            return $alloc->deref_index($binding->data->[1])
                if $binding->data->[0]->hash eq $sym->index->hash;
            $env = $alloc->deref_index($env->data->[1]);
        }
        return undef;
    }

    method BindParams ($params, $args, $env) {
        my $local = $env;
        until ($params->is_nil || $args->is_nil) {
            $local = $alloc->Env( $alloc->Binding( $params->data->[0], $args->data->[0] ), $local );
            ($params, $args) = $alloc->deref_indicies( $params->data->[1], $args->data->[1] );
        }
        die "Arity Mismatch - missing args: ".$self->pprint($params)
            unless $params->is_nil;
        die "Arity Mismatch - extra args: ".$self->pprint($args)
            unless $args->is_nil;
        return $local;
    }

    method BindSymbol ($sym, $val, $env) {
        $alloc->Env( $alloc->Binding( $sym, $val ), $env )
    }

    ## ... closures

    method CaptureClosure ($partial, $env) {
        my ($params, $body, $name) = $alloc->deref_indicies( $partial->data->@* );
        return $alloc->Lambda( $params, $body, $env, $name // () )
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
            my $head;
            ($head, $list) = $alloc->deref_indicies( $list->data->@* );
            push @list => $head;
        }
        return @list;
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

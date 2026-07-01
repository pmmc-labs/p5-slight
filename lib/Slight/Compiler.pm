use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

## -----------------------------------------------------------------------------
## COMPILER NOTES:
## -----------------------------------------------------------------------------
## - BUG! ... defun should not be allowed at the top level
## - consider adding a mutable env (backed by a HASH ref, and parent chain)
##      - use this for the BIF set
##      - use this for the compiled env (with BIF set as parent)
##      - then make Lookup work for both
##          - possibly adding hot paths for builtins, etc.
##      - need to think about if it should be hashed and how/where, etc.
## - consider moving Closure fixup to runtime
##      - other Closures are created at runtime
##      - the compiler could leave a Definition Term in place of the `defun`
##          - the runtime would evaluate it and perform the Closure fixup
## -----------------------------------------------------------------------------

class Compiler {
    field $alloc :param :reader;

    field $root_env;
    field @environs;
    field @top_level;

    my method current_env { $environs[-1] }

    my method fixup_top_level_env {
        my $env = $self->&current_env;
        foreach my $binding (@top_level) {
            my $partial = $alloc->Util->Second( $binding );
            my $lambda  = $alloc->Util->CaptureClosure( $partial, $env );
            $binding->data->[1] = $lambda->index;
        }
        return $env;
    }

    method compile ($exprs, $env=undef) {
        push @environs => ($root_env = ($env // $alloc->Util->InitEnv));
        my @exprs = @$exprs;
        @exprs = map $self->compile_expr($_), @exprs;
        @exprs = grep !$_->is_nil, @exprs;
        return \@exprs, $self->&fixup_top_level_env;
    }

    method compile_expr ($expr) {
        if ($expr isa Cons) {
            my $h = $alloc->Util->Head( $expr );
            my $t = $alloc->Util->Tail( $expr );
            if ($h isa Sym) {
                given ($h->ident) {
                    when ('if') {
                        my ($c, $t, $f) = map $self->compile_expr($_), $alloc->Util->Uncons($t);
                        return $alloc->Condition( $c, $t, $f );
                    }
                    when ('lambda') {
                        my ($p, $b) = $alloc->Util->Uncons($t);
                        return $alloc->Partial( $p, $self->compile_expr($b) );
                    }
                    when ('defun') {
                        my ($name, $p, $b) = $alloc->Util->Uncons($t);
                        my $env    = $self->&current_env;
                        my $lambda = $alloc->Partial( $p, $self->compile_expr($b), $name );
                        push @environs => $alloc->Util->BindSymbol( $name, $lambda, $env );
                        push @top_level => $alloc->Util->First($environs[-1]);
                        return $alloc->Nil;
                    }
                    default {
                        if (my $bif = $alloc->Util->Lookup($h, $root_env)) {
                            return $alloc->Cons( $bif, $self->compile_expr($t) );
                        }
                    }
                }
            }
            return $alloc->Cons( $self->compile_expr($h), $self->compile_expr($t) );
        } else {
            return $expr;
        }
    }
}

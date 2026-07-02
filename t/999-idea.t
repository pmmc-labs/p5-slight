#!perl

use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

class CompilerTwo {
    field $alloc :param :reader;

    method compile ($exprs) {
        +[ map $self->compile_expr($_), @$exprs ]
    }

    my method Tagged ($tag, $rest) {
        $alloc->Pair( $alloc->Tag($tag), $rest )
    }

    my method isTagged ($t, $tag=undef) {
        $t isa Pair && $alloc->Util->First($t) isa Tag
    }

    method compile_expr ($expr) {
        unless ($self->&isTagged($expr)) {
            given (blessed $expr) {
                when ('Sym') {
                    return $self->&Tagged(LOOKUP => $expr);
                }
                when ('Cons') {
                    return $self->compile_expr(
                        $self->&Tagged(EVAL_ARGS => $alloc->Pair( $expr, $alloc->Nil ))
                    );
                }
                default {
                    return $self->&Tagged(PUSH => $expr);
                }
            }
        }
        my $tag  = $alloc->Util->First($expr);
        my $rest = $alloc->Util->Second($expr);
        given ($tag->ident) {
            when ('EVAL_ARGS') {
                my $args = $alloc->Util->First($rest);
                my $done = $alloc->Util->Second($rest);

                return $self->compile_expr($self->&Tagged( APPLY => $done ))
                    if $args->is_nil;

                return $self->compile_expr(
                    $self->&Tagged( EVAL_ARGS =>
                        $alloc->Pair(
                            $alloc->Util->Tail( $args ),
                            $alloc->Cons(
                                $self->compile_expr( $alloc->Util->Head( $args ) ),
                                $done
                            )
                        )
                    )
                )
            }
            when ('APPLY') {
                return $self->&Tagged(APPLY => $alloc->Util->ListOf(map {
                    if ($self->&isTagged($_) && $alloc->Util->Head( $_ )->ident eq 'APPLY') {
                        $alloc->Util->Uncons( $alloc->Util->Tail( $_ ) );
                    } else {
                        $_
                    }
                } $alloc->Util->Uncons($rest)))
            }
            default {
                die "UNKNOWN TAG! ",$tag->ident;
            }
        }
    }
}

my $alloc  = Allocator->new;
my $parser = Parser->new( alloc => $alloc );
my $exprs  = $parser->parse(q[

    (+ (* 2 (- 9 4)) (* 4 (+ 4 1)))

]);

say $alloc->Util->pprint($_) foreach @$exprs;

my $compiler = CompilerTwo->new( alloc => $alloc );

my $compiled = $compiler->compile($exprs);

say $alloc->Util->pprint($_) foreach @$compiled;

__END__

(+ (* 2 (- 9 4)) (* 4 (+ 4 1)))

(PUSH   . 1)
(PUSH   . 4)
(LOOKUP . +)
(PUSH   . 4)
(LOOKUP . *)
(PUSH   . 4)
(PUSH   . 9)
(LOOKUP . -)
(PUSH   . 2)
(LOOKUP . *)
(LOOKUP . +)





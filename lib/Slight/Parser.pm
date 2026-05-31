
use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

## -----------------------------------------------------------------------------
## Parser
## -----------------------------------------------------------------------------

class Slight::Parser {
    field $alloc :param :reader;

    field @stack;

    ADJUST {
        push @stack => +[];
    }

    method tokenizer ($source) {
        if ($source =~ /\;/) {
            $source =~ s/\;.*\n//g;
        }
        grep !/^\s*$/, split /(\'\(|\(|\)|"(?:[^"\\]|\\.)*"|\s)/ => $source;
    }

    method parse ($source) {
        my @tokens = $self->tokenizer($source);
        while (@tokens) {

            my $token = shift @tokens;
            if ($token =~ /^\'[^\(]/) {
                $token =~ s/^\'//;
                push @stack => +[ $alloc->Sym('quote') ];
                unshift @tokens => ')';
            }


            given ($token) {
                when ('\'(') {
                    push @stack => +[ $alloc->Sym('quote') ];
                }
                when ('(') {
                    push @stack => +[];
                }
                when (')') {
                    my $list = pop @stack;
                    push $stack[-1]->@*, $alloc->List( $list->@* );
                }
                when (/^\"/) {
                    push $stack[-1]->@*, $alloc->Str( substr($token, 1, -1) );
                }
                when (/^\d+$/) {
                    push $stack[-1]->@*, $alloc->Num($token);
                }
                when ('nil') {
                    push $stack[-1]->@*, $alloc->Nil;
                }
                when ('true') {
                    push $stack[-1]->@*, $alloc->True;
                }
                when ('false') {
                    push $stack[-1]->@*, $alloc->False;
                }
                default {
                    if ($token =~ /^\:/) {
                        push $stack[-1]->@*, $alloc->Tag($token);
                    } else {
                        push $stack[-1]->@*, $alloc->Sym($token);
                    }
                }
            }
        }
        return $stack[-1]->@*;
    }

}



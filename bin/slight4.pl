use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];
use Data::Dumper qw[ Dumper ];
use Time::HiRes  qw[ gettimeofday tv_interval ];

use constant DEBUG => $ENV{DEBUG} // 0;
use Term::ReadKey (); our $TERM_WIDTH = (Term::ReadKey::GetTerminalSize)[0];

use Digest::MD5 ();

## -----------------------------------------------------------------------------

class Term {
    field $index :param :reader;
    field $data  :param :reader;
    method is_nil { false }
    method equal_to ($o) { $index->hash eq $o->index->hash }
}

class Sym     :isa(Term) { method ident { $self->data->[0] } }
class Str     :isa(Term) { method value { $self->data->[0] } }
class Num     :isa(Term) { method value { $self->data->[0] } }
class Bool    :isa(Term) {
    method is_true  { $self->data->[0] eq '#true' }
    method is_false { $self->data->[0] eq '#false' }
}
class Nil     :isa(Term) { method is_nil { true } }
class Cons    :isa(Term) {
    method head { $self->data->[0] }
    method tail { $self->data->[0] }
}

# Env is a list of pairs
class Env :isa(Cons) {}

# Pair is a cons where tail is not a list
class Pair :isa(Cons) {
    method first  { $self->head }
    method second { $self->tail }
}

class Lambda :isa(Term) {
    method params { $self->data->[0] }
    method body   { $self->data->[1] }
    method env    { $self->data->[2] }
    method name   { $self->data->[3] }
}

class Condition :isa(Term) {
    method cond     { $self->data->[0] }
    method if_true  { $self->data->[1] }
    method if_false { $self->data->[2] }
}

class Builtin :isa(Term) {
    method name { $self->data->[0] }
    method raw  { $self->data->[1] }
}

## -----------------------------------------------------------------------------

class Allocator::Utils {
    field $alloc :param :reader;

    ## ... environs

    method InitEnv (@bindings) {
        my $env = $alloc->Nil;
        foreach my ($sym, $val) (@bindings) {
            $env = $alloc->Env( $alloc->Pair( $sym, $val ), $env );
        }
        return $env;
    }

    method Lookup ($sym, $env) {
        return undef if $env->is_nil;
        my $candidate = $self->First($env);
        if ($self->First($candidate)->equal_to($sym)) {
            return $self->Second($candidate);
        } else {
            return $self->Lookup($sym, $self->Rest($env));
        }
    }

    method BindSymbol ($sym, $val, $env) {
        $alloc->Env( $alloc->Pair( $sym, $val ), $env )
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

    method First  ($t) { $alloc->deindex($t->data->[0]) }
    method Second ($t) { $alloc->deindex($t->data->[1]) }
    method Third  ($t) { $alloc->deindex($t->data->[2]) }
    method Fourth ($t) { $alloc->deindex($t->data->[3]) }

    method Rest   ($t) { $alloc->deindex($t->data->[1]) }
    method Head   ($l) { $alloc->deindex($l->data->[0]) }
    method Tail   ($l) { $alloc->deindex($l->data->[1]) }

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
            when ('Nil')     { '#nil' }
            when ('Cons')    { sprintf '(%s)' => join ' ' => map $self->pprint($_), $alloc->Util->Uncons($t) }
            when ('Pair')    { sprintf '(%s . %s)' => $self->pprint($self->First($t)), $self->pprint($self->Second($t)) }
            when ('Env')     { sprintf '{ %s }' => join ' ' => map $self->pprint($_), $alloc->Util->Uncons($t) }
            when ('Builtin') { sprintf '<%s>' => $self->pprint($self->First($t)) }
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
            (substr $t->index->hash, 0, 6),
            (join ' ' => map {
                blessed $_
                    ? (sprintf '$(%05d)' => $_->idx)
                    : (length $_ > 33 ? (substr($_, 0, 33).' ...') : $_)
            } $t->data->@*),
            ($TERM_WIDTH > 70 ? substr($self->pprint($t), 0, ($TERM_WIDTH - 73)) : '')
        )
    }
}

class Index {
    field $idx  :param :reader;
    field $hash :param :reader;
}

class Allocator {
    field @memory :reader;
    field %intern :reader;
    field %native :reader;

    field $Nil;
    field $True;
    field $False;

    field $Util :reader;

    method deindex ($index) { $memory[ $index->idx ] }
    method deref   ($index) { $native{ $index->hash } }

    my method intern ($type, @payload) {
        my $hash = Digest::MD5::md5_hex(
            join '/' => $type,
                join ':' =>
                    ($type eq 'Lambda'
                        ? (grep { not($_ isa Env) } @payload)
                        : @payload)
        );
        return $memory[ $intern{ $hash }->idx ] if exists $intern{ $hash };
        my $index = Index->new( idx => (scalar @memory), hash => $hash );
        my $value = $type->new(
            index => $index,
            data  => [ map { blessed $_ ? $_->index : $_ } @payload ]
        );
        push @memory => $value;
        $intern{$hash} = $index;
        return $value;
    }

    ADJUST {
        $Nil   = $self->&intern( Nil  => '#nil'   );
        $True  = $self->&intern( Bool => '#true'  );
        $False = $self->&intern( Bool => '#false' );
        $Util  = Allocator::Utils->new( alloc => $self );
    }

    method Nil   { $Nil }
    method True  { $True }
    method False { $False }

    method Bool ($value) { $value ? $True : $False }
    method Sym  ($ident) { $self->&intern( Sym  => $ident ) }
    method Num  ($value) { $self->&intern( Num  => $value ) }
    method Str  ($value) { $self->&intern( Str  => $value ) }
    method Cons ($h, $t) { $self->&intern( Cons => $h, $t ) }
    method Pair ($f, $s) { $self->&intern( Pair => $f, $s ) }
    method Env  ($p, $r) { $self->&intern( Env  => $p, $r ) }

    method Condition ($c, $t, $f) {
        $self->&intern( Condition => $c, $t, $f )
    }

    method Lambda ($p, $b, $e, $name=undef) {
        $self->&intern( Lambda => $p, $b, $e, $name // () )
    }

    method Builtin ($name, $f) {
        my $bif = $self->&intern( Builtin => $name );
        $native{ $bif->index->hash } //= $f;
        return $bif;
    }
}

## -----------------------------------------------------------------------------

class Parser {
    field $alloc  :param :reader;
    field @chars  :reader;
    field @tokens :reader;

    method peek    { $chars[0] }
    method advance { shift @chars }

    method skip_whitespace {
        while (@chars) {
            last if $chars[0] =~ /\S/;
            shift @chars
        }
    }

    method skip_until_newline {
        while (@chars) {
            last if $chars[0] =~ /\n/;
            shift @chars
        }
    }

    method push_stack ($value) { push $tokens[-1]->@* => $value }
    method pop_stack           { pop $tokens[-1]->@* }

    method parse ($source) {
        @tokens = (+[]);
        @chars  = split // => $source;
        while (@chars) {
            $self->find_next_token;
        }
        return pop @tokens;
    }

    method find_next_token {
        my $next = $self->advance;
        given ($next) {
            when (/\s/)    { $self->skip_whitespace }
            when (';')     { $self->skip_until_newline }
            when ('(')     { push @tokens => +[] }
            when (')')     { $self->push_stack( $alloc->Util->ListOf( @{ pop @tokens } ) ) }
            when (/[0-9]/) { $self->push_stack( $alloc->Num( $self->parse_number( $next ) ) ) }
            when ('"')     { $self->push_stack( $alloc->Str( $self->parse_string( $next ) ) ) }
            when ('-')     { $self->peek =~ /[0-9]/
                ? $self->push_stack( $alloc->Num( $self->parse_number( $next ) ) )
                : $self->push_stack( $alloc->Sym( $self->parse_symbol( $next ) ) )
            }
            when ('#') {
                given ($self->peek) {
                    when ('t') { $self->advance; $self->push_stack( $alloc->True ) }
                    when ('f') { $self->advance; $self->push_stack( $alloc->False ) }
                    when ('n') { $self->advance; $self->push_stack( $alloc->Nil ) }
                    default {
                        $self->push_stack( $alloc->Sym( $self->parse_symbol( $next ) ) );
                    }
                }
            }
            default {
                $self->push_stack( $alloc->Sym( $self->parse_symbol( $next ) ) );
            }
        }
    }

    method parse_number ($start) {
        $self->peek =~ /[0-9.]/
            ? $self->parse_number( $start . $self->advance )
            : $start;
    }

    method parse_string ($start) {
        if ($self->peek eq '\\') {
            $start .= $self->advance;
            $start .= $self->advance if $self->peek eq '"';
            $self->parse_string( $start );
        } elsif ($self->peek eq '"') {
            $start . $self->advance;
        } else {
            $self->parse_string( $start . $self->advance );
        }
    }

    method parse_symbol ($start) {
        $self->peek !~ /[\s\(\)]/
            ? $self->parse_symbol( $start . $self->advance )
            : $start;
    }
}

## -----------------------------------------------------------------------------

class Compiler {
    field $alloc :param :reader;

    field $root_env;
    field @environs;
    field @top_level;

    my method current_env { $environs[-1] }

    my method seal_top_level {
        my $env_idx = $self->&current_env->index;
        $_->data->[2] = $env_idx foreach @top_level;
    }

    method compile ($exprs, $env=undef) {
        push @environs => ($root_env = ($env // $alloc->Util->InitEnv));
        my @exprs = @$exprs;
        @exprs = map $self->compile_expr($_), @exprs;
        @exprs = grep !$_->is_nil, @exprs;
        $self->&seal_top_level;
        return \@exprs, $self->&current_env;
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
                        return $alloc->Lambda( $p, $self->compile_expr($b), $self->&current_env );
                    }
                    when ('defun') {
                        my ($name, $p, $b) = $alloc->Util->Uncons($t);
                        my $env    = $self->&current_env;
                        my $lambda = $alloc->Lambda( $p, $self->compile_expr($b), $env, $name );
                        push @environs => $alloc->Util->BindSymbol( $name, $lambda, $env );
                        push @top_level => $lambda;
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

## -----------------------------------------------------------------------------

class Interpreter::ASTWalker {
    field $alloc :param :reader;

    my method LOG ($depth, $fmt, @args) {
        my $indent = '';
        $indent = '  ' x $depth if $depth > 0;
        say $indent, sprintf $fmt, map $alloc->Util->pprint($_), @args;
    }

    method run ($exprs, $env) {
        my $depth  = 0;
        my $result = $alloc->Nil;
        foreach my $expr (@$exprs) {
            $result = $self->evaluate($expr, $env);
            ::DEBUG && $self->&LOG( $depth, '... statement ended with %s' => $result );
        }
        return $result;
    }

    method apply ($call, $args, $env, $depth=0) {
        ::DEBUG && $self->&LOG( $depth, 'APPLY %s %s' => $call, $args);
        given (blessed $call) {
            when ('Builtin') {
                my $native = $alloc->deref( $call->index );
                return $native->( $args );
            }
            when ('Lambda') {
                my $params = $alloc->Util->First($call);
                my $body   = $alloc->Util->Second($call);
                my $local  = $alloc->Util->Third($call);
                return $self->evaluate( $body, $alloc->Util->BindParams( $params, $args, $local ), $depth + 1 )
            }
            default { die 'WTF! cant apply a '.$alloc->Util->pprint($call) }
        }
    }

    method evaluate_args ($args, $env, $depth=0) {
        return $args if $args->is_nil;
        ::DEBUG && $self->&LOG( $depth, 'EVAL/ARGS %s' => $args );
        return $alloc->Cons(
            $self->evaluate( $alloc->Util->Head($args), $env, $depth + 1 ),
            $self->evaluate_args( $alloc->Util->Tail($args), $env, $depth + 1 )
        )
    }

    method evaluate ($expr, $env, $depth=0) {
        ::DEBUG && $self->&LOG( $depth, 'EVAL %s' => $expr );
        given (blessed $expr) {
            when ('Sym') {
                ::DEBUG && $self->&LOG( $depth + 1, 'LOOKUP %s' => $expr );
                if (my $found = $alloc->Util->Lookup($expr, $env)) {
                    return $found;
                } else {
                    die "Could not find (".$alloc->Util->pprint($expr).") in Env";
                }
            }
            when ('Cons') {
                my $head = $alloc->Util->Head($expr);
                ::DEBUG && $self->&LOG( $depth, 'EVAL/HEAD %s' => $head );
                return $self->apply(
                    $self->evaluate( $head, $env, $depth + 1 ),
                    $self->evaluate_args( $alloc->Util->Tail($expr), $env, $depth + 1 ),
                    $env,
                    $depth
                )
            }
            when ('Condition') {
                ::DEBUG && $self->&LOG( $depth, 'COND');
                my $result = $self->evaluate( $alloc->Util->First($expr), $env, $depth + 1 );
                if ($result isa Bool && $result->is_true) {
                    ::DEBUG && $self->&LOG( $depth, 'BRANCH %s' => $result);
                    return $self->evaluate( $alloc->Util->Second($expr), $env, $depth + 1 );
                } else {
                    ::DEBUG && $self->&LOG( $depth, 'BRANCH %s' => $result);
                    return $self->evaluate( $alloc->Util->Third($expr), $env, $depth + 1 );
                }
            }
            default {
                return $expr;
            }
        }
    }
}


## -----------------------------------------------------------------------------

class Interpreter::CEK {
    field $alloc :param :reader;

    field $steps :reader = 0;

    my method LOG ($fmt, @args) {
        my $indent = '';
        my $depth  = 0;
        1 while caller( ++$depth );
        say sprintf("%05d | ${fmt}", $steps, map {
                blessed $_
                    ? $_ isa Env
                        ? substr($_->index->hash, 0, 6)
                        : $alloc->Util->pprint($_)
                    : $_
                } @args)
    }

    method run ($exprs, $env) {
        my @exprs = @$exprs;
        return $self->execute(shift @exprs, $env, sub ($c, $e) {
            return $c, $e, undef if scalar @exprs == 0;
            return shift @exprs, $env, __SUB__;
        })
    }

    method execute ($expr, $env, $kont) {
        ::DEBUG && $self->&LOG('>> BEGIN %s %s' => $expr, $env);
        while (true) {
            $steps++;
            ::DEBUG && say '-' x $::TERM_WIDTH;
            ($expr, $env, $kont) = defined $expr ? $self->evaluate( $expr, $env, $kont ) : $kont->();
            last if not defined $kont;
        }
        ::DEBUG && $self->&LOG('<< END %s %s' => $expr, $env);
        return $expr;
    }

    my method return_value ($expr, $env, $kont) {
        return undef, $env, sub { $kont->( $expr, $env ) };
    }

    method evaluate ($expr, $env, $kont) {
        ::DEBUG && $self->&LOG('~> EVAL %s' => $expr);
        given (blessed $expr) {
            when ('Sym') {
                ::DEBUG && $self->&LOG('?> LOOKUP %s', $expr);
                if (my $found = $alloc->Util->Lookup($expr, $env)) {
                    ::DEBUG && $self->&LOG('<? FOUND %s := %s', $expr, $found);
                    return $self->&return_value( $found, $env, $kont );
                } else {
                    return $alloc->Str("Could not find (".$alloc->Util->pprint($expr).") in Env".$alloc->Util->pprint($env)), $env, undef;
                }
            }
            when ('Cons') {
                my $head = $alloc->Util->Head($expr);
                my $tail = $alloc->Util->Tail($expr);
                ::DEBUG && $self->&LOG('-> EVAL/HEAD %s', $head);
                return $head, $env, sub ($call, $e) {
                    ::DEBUG && $self->&LOG('<- EVAL/HEAD %s ~ %s', $head, $call);
                    return $self->evaluate_args( $call, $tail, $e, $kont )
                }
            }
            when ('Condition') {
                my $cond     = $alloc->Util->First($expr);
                my $if_true  = $alloc->Util->Second($expr);
                my $if_false = $alloc->Util->Third($expr);
                ::DEBUG && $self->&LOG('?> COND %s', $cond);
                return $cond, $env, sub ($result, $e) {
                    ::DEBUG && $self->&LOG('<? COND %s ~ %s', $cond, $result);
                    if ($result isa Bool && $result->is_true) {
                        return $if_true, $e, $kont;
                    } else {
                        return $if_false, $e, $kont;
                    }
                }
            }
            default {
                ::DEBUG && $self->&LOG('<- RETURN %s', $expr);
                return $self->&return_value( $expr, $env, $kont );
            }
        }
    }

    method evaluate_args ($call, $args, $env, $kont) {
        ::DEBUG && $self->&LOG('+> EVAL/ARGS %s -> ()', $args);
        my $first = $alloc->Util->Head( $args );
        my $rest  = $alloc->Util->Tail( $args );
        my $done  = $alloc->Nil;
        return $first, $env, sub ($arg, $e) {
            $done = $alloc->Cons( $arg, $done );
            if ($rest->is_nil) {
                ::DEBUG && $self->&LOG('<+ EVAL/ARGS () <- %s', $done);
                return $self->apply( $call, $alloc->Util->Reverse( $done ), $env, $kont );
            } else {
                ::DEBUG && $self->&LOG('<< EVAL/ARGS %s ~ %s', $rest, $done);
                my $next = $alloc->Util->Head($rest);
                $rest = $alloc->Util->Tail($rest);
                return $next, $e, __SUB__;
            }
        }
    }

    method apply ($call, $args, $env, $kont) {
        ::DEBUG && $self->&LOG('@> APPLY %s %s', $call, $args);
        given (blessed $call) {
            when ('Builtin') {
                ::DEBUG && $self->&LOG('@! APPLY/BIF %s %s', $call, $args);
                my $native = $alloc->deref( $call->index );
                return $native->( $args ), $env, $kont;
            }
            when ('Lambda') {
                ::DEBUG && $self->&LOG('@! APPLY/LAMBDA %s %s', $call, $args);
                my $params = $alloc->Util->First($call);
                my $body   = $alloc->Util->Second($call);
                my $local  = $alloc->Util->Third($call);
                return $body, $alloc->Util->BindParams( $params, $args, $local ), sub ($c, $e) {
                    ::DEBUG && $self->&LOG('@< LEAVE (%s) ^(%s)', $e, $env);
                    return $c, $env, $kont;
                }
            }
            default {
                return $alloc->Str("Could not call (".$alloc->Util->pprint($call).")"), $env, undef;
            }
        }
    }


}

## -----------------------------------------------------------------------------

my $a = Allocator->new;
my $p = Parser->new( alloc => $a );
my $c = Compiler->new( alloc => $a );

my $ast = Interpreter::ASTWalker->new( alloc => $a );
my $cek = Interpreter::CEK->new( alloc => $a );

sub liftBoolBinOp ($a, $op, $f) {
    my $name = $a->Sym($op);
    return $name, $a->Builtin( $name, sub ($args) {
        my ($n, $m) = $a->Util->Uncons($args);
        return $a->Bool( $f->( $n->value, $m->value ) );
    })
}

sub liftNumBinOp ($a, $op, $f) {
    my $name = $a->Sym($op);
    return $name, $a->Builtin( $name, sub ($args) {
        my ($n, $m) = $a->Util->Uncons($args);
        return $a->Num( $f->( $n->value, $m->value ) );
    })
}

my $bif = $a->Util->InitEnv(
    liftBoolBinOp($a, '==', sub ($n, $m) { $n == $m }),
    liftBoolBinOp($a, '!=', sub ($n, $m) { $n != $m }),
    liftBoolBinOp($a, '>',  sub ($n, $m) { $n >  $m }),
    liftBoolBinOp($a, '>=', sub ($n, $m) { $n >= $m }),
    liftBoolBinOp($a, '<',  sub ($n, $m) { $n <  $m }),
    liftBoolBinOp($a, '<=', sub ($n, $m) { $n <= $m }),

    liftNumBinOp($a, '+', sub ($n, $m) { $n + $m }),
    liftNumBinOp($a, '-', sub ($n, $m) { $n - $m }),
    liftNumBinOp($a, '*', sub ($n, $m) { $n * $m }),
    liftNumBinOp($a, '/', sub ($n, $m) { $n / $m }),
    liftNumBinOp($a, '%', sub ($n, $m) { $n / $m }),
);

my $SOURCE = q[

    (defun fact (n)
        (if (== n 0) 1
            (* n (fact (- n 1)))))

    (defun fib (n)
        (if (< n 2) n
            (+ (fib (- n 1)) (fib (- n 2)))))

    (fact (fib 6))
];

say '=' x $TERM_WIDTH;
say 'SOURCE:';
say '-' x $TERM_WIDTH;
say $SOURCE;
say '';
say '=' x $TERM_WIDTH;
say 'PARSING LOG:';
say '-' x $TERM_WIDTH;
my $parsed = $p->parse($SOURCE);
say '-' x $TERM_WIDTH;
say 'PARSED:';
say '-' x $TERM_WIDTH;
say $a->Util->DUMP($_) foreach @$parsed;
say '=' x $TERM_WIDTH;
say '';
say '=' x $TERM_WIDTH;
say 'COMPILIER LOG:';
say '-' x $TERM_WIDTH;
my ($compiled, $e) = $c->compile( $parsed, $bif );
say '-' x $TERM_WIDTH;
say 'COMPILED:';
say '-' x $TERM_WIDTH;
say $a->Util->DUMP($_) foreach @$compiled;
say '=' x $TERM_WIDTH;

if ($ENV{AST}) {
    say '';
    say '=' x $TERM_WIDTH;
    say 'RUNNING LOG(AST):';
    say '-' x $TERM_WIDTH;
    my $start   = [gettimeofday];
    my $evaled  = $ast->run( $compiled, $e );
    my $elapsed = tv_interval ( $start, [gettimeofday]);
    say '=' x $TERM_WIDTH;
    say sprintf 'RESULT(AST) completed in %f seconds', $elapsed;
    say '-' x $TERM_WIDTH;
    say $a->Util->DUMP($evaled);
    say '=' x $TERM_WIDTH;
}

if ($ENV{CEK}) {
    say '';
    say '=' x $TERM_WIDTH;
    say 'RUNNING LOG(CEK)';
    say '-' x $TERM_WIDTH;
    my $start   = [gettimeofday];
    my $evaled = $cek->run( $compiled, $e );
    my $elapsed = tv_interval ( $start, [gettimeofday]);
    say '=' x $TERM_WIDTH;
    say sprintf 'RESULT(CEK) completed in %f seconds', $elapsed;
    say '-' x $TERM_WIDTH;
    say $a->Util->DUMP($evaled);
    say '=' x $TERM_WIDTH;
}

if ($ENV{MEM}) {
    say '';
    say '=' x $TERM_WIDTH;
    say 'MEMORY:';
    say '-' x $TERM_WIDTH;
    say $a->Util->DUMP($_) foreach $a->memory;
    say '=' x $TERM_WIDTH;
}
## -----------------------------------------------------------------------------

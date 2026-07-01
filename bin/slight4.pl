use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];
use Data::Dumper qw[ Dumper ];
use Time::HiRes  qw[ gettimeofday tv_interval ];
use Sub::Util    qw[ set_subname ];
use List::Util   qw[ sum ];

use constant DEBUG => $ENV{DEBUG} // 0;
use Term::ReadKey (); our $TERM_WIDTH = (Term::ReadKey::GetTerminalSize)[0] // 300;

use Digest::MD5 ();

## -----------------------------------------------------------------------------

class Term {
    field $index :param :reader;
    field $data  :param :reader;
    method is_nil { false }
    method equal_to ($o) { $index->hash eq $o->index->hash }
    method short_hash { substr($index->hash, 0, 6) }
}

class Sym     :isa(Term) { method ident { $self->data->[0] } }
class Str     :isa(Term) { method value { $self->data->[0] } }
class Num     :isa(Term) { method value { $self->data->[0] } }
class Bool    :isa(Term) {
    method is_true  { $self->data->[0] eq '#t' }
    method is_false { $self->data->[0] eq '#f' }
}
class Nil     :isa(Term) { method is_nil { true } }
class Cons    :isa(Term) {} # head, tail
class Pair    :isa(Cons) {} # Pair is a cons where tail is not a list
class Env     :isa(Cons) {} # Env is a list of pairs

# compile-time version (w/ out env)
class Partial :isa(Term) { # params, body, name?
    method has_name { defined $self->data->[2] }
}

# runtime-time version (w/ captured runtime env)
class Lambda  :isa(Term) { # params, body, env, name?
    method has_name { defined $self->data->[3] }
}

class Condition :isa(Term) {} # condition, if-true, if-false
class Builtin   :isa(Term) {} # name, CODE

## -----------------------------------------------------------------------------
## ALLOCATOR NOTES:
## -----------------------------------------------------------------------------
## - in a number of cases I can probably skip inflating objects
##      - remember, the hash is structural
##          - and so some things can be compared using only that
## - the Env helpers are hot paths, look for optimizations
##      - but not at the cost of correctness
## - Cons can create improper lists
##      - ... and other places I need to add type checks
## - clean up stat keys, they are poorly named
## -----------------------------------------------------------------------------

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
            $env = $alloc->Env( $alloc->Pair( $sym, $val ), $env );
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
    field $stats  :reader = +{
        total_requests    => 0,
        total_fulfilled   => 0,
        requested_by_hash => +{},
        created_by_type   => +{},
    };

    field $Nil;
    field $True;
    field $False;

    field $Util :reader;

    method deref_hash   ($hash)  { $memory[ $intern{ $hash }->idx ] }
    method deref_index  ($index) { $memory[ $index->idx  ] }
    method deref_native ($index) { $native{ $index->hash } }

    my method intern ($type, @payload) {
        # NOTE: I know, I know, MD5 is just a placeholder
        my $hash = Digest::MD5::md5_hex(
            join '/' => $type,
                join ':' =>
                    map { blessed $_ ? $_->index->hash : $_ } @payload
        );
        $stats->{total_requests}++;
        $stats->{requested_by_hash}->{ $hash }++;
        return $memory[ $intern{ $hash }->idx ] if exists $intern{ $hash };
        $stats->{created_by_type}->{ $type }++;
        $stats->{total_fulfilled}++;
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
        $Nil   = $self->&intern( Nil  => '()' );
        $True  = $self->&intern( Bool => '#t' );
        $False = $self->&intern( Bool => '#f' );
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

    method Partial ($p, $b, $name=undef) {
        $self->&intern( Partial => $p, $b, $name // () )
    }

    method Builtin ($name, $f) {
        my $bif = $self->&intern( Builtin => $name );
        $native{ $bif->index->hash } //= $f;
        return $bif;
    }
}

## -----------------------------------------------------------------------------
## PARSER TODO:
## -----------------------------------------------------------------------------
## - fix string creation (remove the "")
## - fix number parsing (it's just bad)
## - improve error handling
## - track line numbers and char spans (for errors, etc)
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

## -----------------------------------------------------------------------------
## INTERPRETER NOTES
## -----------------------------------------------------------------------------
## - Unify error handling between interpreters
## - consider a "stack allocator" for temporary values (
##      - especially Cons cells and temp Nums during calculations
## -----------------------------------------------------------------------------

class Interpreter::ASTWalker {
    field $alloc :param :reader;

    my method LOG ($depth, $fmt, @args) {
        my $indent = '';
        $indent = '  ' x $depth if $depth > 0;
        say $indent, sprintf $fmt, map blessed $_ ? $alloc->Util->pprint($_) : $_, @args;
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
                my $native = $alloc->deref_native( $call->index );
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
            when ('Partial') {
                ::DEBUG && $self->&LOG( $depth, 'CLOSING OVER %s @ %s' => $expr, $env->short_hash );
                return $alloc->Util->CaptureClosure( $expr, $env );
            }
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
        #my $indent = '';
        #my $depth  = 0;
        #1 while caller( ++$depth );
        say sprintf("%05d | ${fmt}", $steps, map {
                blessed $_
                    ? $_ isa Env
                        ? $_->short_hash
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
            when ('Partial') {
                ::DEBUG && $self->&LOG('() CLOSING OVER %s @ %s' => $expr, $env->short_hash );
                return $self->&return_value( $alloc->Util->CaptureClosure( $expr, $env ), $env, $kont );
            }
            when ('Sym') {
                ::DEBUG && $self->&LOG('?> LOOKUP %s', $expr);
                if (my $found = $alloc->Util->Lookup($expr, $env)) {
                    ::DEBUG && $self->&LOG('<? FOUND %s := %s', $expr, $found);
                    return $self->&return_value( $found, $env, $kont );
                } else {
                    return $alloc->Str("Could not find (".$alloc->Util->pprint($expr).") in Env".$env->short_hash), $env, undef;
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
                my $native = $alloc->deref_native( $call->index );
                return $self->&return_value( $native->( $args ), $env, $kont );
            }
            when ('Lambda') {
                ::DEBUG && $self->&LOG('@! APPLY/LAMBDA %s %s', $call, $args);
                my $params = $alloc->Util->First($call);
                my $body   = $alloc->Util->Second($call);
                my $local  = $alloc->Util->Third($call);
                return $body, $alloc->Util->BindParams( $params, $args, $local ), sub ($c, $e) {
                    ::DEBUG && $self->&LOG('@< LEAVE (%s) ^(%s)', $e, $env);
                    return $self->&return_value( $c, $env, $kont );
                }
            }
            default {
                return $alloc->Str("Could not call (".$alloc->Util->pprint($call).")"), $env, undef;
            }
        }
    }
}

## -----------------------------------------------------------------------------
## RUNTIME NOTES
## -----------------------------------------------------------------------------
## - Create runtime layer to manage:
##      - the central allocator
##      - the BIF environment
##          - and the lift*Op helpers
##      - parsing/compiling code
##      - top-level namespace management
##          - handling loading code from modules, etc.
##      - running different interpreters
##          - possibly comparing outputs
##      - dumping stats, etc.
## - some other ideas ...
##      - Add a REPL
##      - Add a CLI
##      - Create a test harness and test framework
##          - create a new "TopLevelEnv" with testing functions in it
##      - add I/O channels for interpreters to read/write to/from
## -----------------------------------------------------------------------------

my $alloc = Allocator->new;
my $p = Parser->new( alloc => $alloc );
my $c = Compiler->new( alloc => $alloc );

my $ast = Interpreter::ASTWalker->new( alloc => $alloc );
my $cek = Interpreter::CEK->new( alloc => $alloc );

sub liftBoolBinOp ($alloc, $op, $f) {
    my $name = $alloc->Sym($op);
    return $name, $alloc->Builtin( $name, set_subname "/BinOp/Bool/${op}" => sub ($args) {
        my ($n, $m) = $alloc->Util->Uncons($args);
        return $alloc->Bool( $f->( $n->value, $m->value ) );
    })
}

sub liftNumBinOp ($alloc, $op, $f) {
    my $name = $alloc->Sym($op);
    return $name, $alloc->Builtin( $name, set_subname "/BinOp/Num/${op}" => sub ($args) {
        my ($n, $m) = $alloc->Util->Uncons($args);
        return $alloc->Num( $f->( $n->value, $m->value ) );
    })
}

sub liftTermBinOp ($alloc, $op, $f) {
    my $name = $alloc->Sym($op);
    return $name, $alloc->Builtin( $name, set_subname "/BinOp/*/${op}" => sub ($args) {
        my ($n, $m) = $alloc->Util->Uncons($args);
        return $f->( $n, $m );
    })
}

sub liftTermUnOp ($alloc, $op, $f) {
    my $name = $alloc->Sym($op);
    return $name, $alloc->Builtin( $name, set_subname "/UnOp/*/${op}" => sub ($args) {
        my $n = $alloc->Util->Head($args);
        return $f->( $n );
    })
}

sub liftTermListOp ($alloc, $op, $f) {
    my $name = $alloc->Sym($op);
    return $name, $alloc->Builtin( $name, set_subname "/ListOp/*/${op}" => sub ($args) {
        my @args = $alloc->Util->Uncons($args);
        return $f->( @args );
    })
}

$alloc->Str("BEFORE BIF CREATION");

my $bif = $alloc->Util->InitEnv(
    liftBoolBinOp($alloc, '==', sub ($n, $m) { $n == $m }),
    liftBoolBinOp($alloc, '!=', sub ($n, $m) { $n != $m }),
    liftBoolBinOp($alloc, '>',  sub ($n, $m) { $n >  $m }),
    liftBoolBinOp($alloc, '>=', sub ($n, $m) { $n >= $m }),
    liftBoolBinOp($alloc, '<',  sub ($n, $m) { $n <  $m }),
    liftBoolBinOp($alloc, '<=', sub ($n, $m) { $n <= $m }),

    liftNumBinOp($alloc, '+', sub ($n, $m) { $n + $m }),
    liftNumBinOp($alloc, '-', sub ($n, $m) { $n - $m }),
    liftNumBinOp($alloc, '*', sub ($n, $m) { $n * $m }),
    liftNumBinOp($alloc, '/', sub ($n, $m) { $n / $m }),
    liftNumBinOp($alloc, '%', sub ($n, $m) { $n % $m }),

    liftTermBinOp($alloc, 'eq?', sub ($n, $m) { $alloc->Bool(  $n->equal_to($m) ) }),
    liftTermBinOp($alloc, 'ne?', sub ($n, $m) { $alloc->Bool( !$n->equal_to($m) ) }),

    liftTermListOp($alloc, 'list', sub (@items) { $alloc->Util->ListOf(@items) }),
    liftTermBinOp ($alloc, 'cons', sub ($h, $t) { $alloc->Cons( $h, $t )       }),
    liftTermUnOp  ($alloc, 'nil?', sub ($t)     { $alloc->Bool( $t->is_nil )   }),
    liftTermUnOp  ($alloc, 'head', sub ($l)     { $alloc->Util->Head($l)       }),
    liftTermUnOp  ($alloc, 'tail', sub ($l)     { $alloc->Util->Tail($l)       }),
);

my $SOURCE = q[

    (defun adder (n m) (+ n m))

    (defun double (n) (adder n n))

    (defun fact (n)
        (if (== n 0) 1
            (* n (fact (- n 1)))))

    (defun fib (n)
        (if (< n 2) n
            (+ (fib (- n 1)) (fib (- n 2)))))

    (defun tail-call-demo (n)
        (if (== n 0) 0
           (tail-call-demo (- n 1))))

    (defun length (lst)
        (if (nil? lst) 0
            (+ 1 (length (tail lst)))))

    (defun length-iter (lst count)
        (if (nil? lst) count
            (length-iter (tail lst) (+ count 1))))

    (defun range (b e)
        (if (== b e)
            (cons e ())
            (cons b (range (+ b 1) e))))

    (defun map (f lst)
        (if (nil? lst) ()
            (cons (f (head lst)) (map f (tail lst)))))

    (defun grep (f lst)
        (if (nil? lst) ()
            (if (f (head lst))
                (cons (head lst) (grep f (tail lst)))
                (grep f (tail lst)))))

    (defun reduce (acc f lst)
        (if (nil? lst) acc
            (reduce (f (head lst) acc) f (tail lst))))

    (defun sum (lst)
        (reduce 0 (lambda (n acc) (+ acc n)) lst))

    (defun product (lst)
        (reduce 1 (lambda (n acc) (* acc n)) lst))

    (defun even? (n) (if (== n 0) #t (odd?  (- n 1))))
    (defun odd?  (n) (if (== n 0) #f (even? (- n 1))))

    (defun make-adder (n) (lambda (x) (+ x n)))

    (list
        (even? 10)
        (odd? 10)
        (fact 6)
        (fib 6)
        (fact (fib 6))
        (length (list 1 2 3 4 5))
        (length-iter (list 1 2 3 4 5) 0)
        (tail-call-demo 10)
        ;; bunch of silly ways to get 30
        (length (list
            30
            (+ 10 20)
            (+ (* 2 5) 20)
            (+ 10 (* 4 5))
            (+ (* 2 5) (* 4 5))
            (+ (* 2 (- 9 4)) (* 4 5))
            (+ (* 2 (- 9 4)) (* 4 (+ 4 1)))
            (adder 10 20)
            (adder (double 5) 20)
            (adder 10 (* (double 2) 5))
            (adder (fib 6) 22)
            (adder (fib 8) (+ 1 (double 4)))
            (- (fact 6) (+ (* (fact 3) 100) 90))
            ((lambda (n m) (+ n m)) 10 20)
            ((lambda (f n m) (f n m)) + 10 20)
            (+ (length (list 0 1 2 3 4 5 6 7 8 9)) 20)
            (length (range 1 30))
            (+ (length (range 1 10)) (length (range 1 (* 4 5))))
            (+ (product (list 2 1 5)) (sum (list 2 4 6 8)))
            (sum (list 4 (fib 8) (- (fact 3) 1)))
            (+ (sum (range 0 (fib 6))) (- 2 8))
            (sum (grep
                    (lambda (x) (>= x 10))
                    (list 0 2 10 4 7 20 3 1)))
            (sum (map
                    (lambda (x) (if (<= x 20) x 0))
                    (list 100 25 10 411 75 20 35 1000)))
            (if (even? (* 2 5)) (+ (* 2 5) 20) -1)
            (if (even? (* 3 5)) -1 (if (odd? (* 3 5)) 30 -1))
            ((make-adder 10) 20)
            ((make-adder 20) 10)
        ))
        "<- all done!"
    )
];

say '=' x $TERM_WIDTH;
say 'SOURCE:';
say '-' x $TERM_WIDTH;
say $SOURCE;
say '';
say '=' x $TERM_WIDTH;
say 'PARSING LOG:';
say '-' x $TERM_WIDTH;
$alloc->Str("BEFORE PARSING");
my $parsed = $p->parse($SOURCE);
say '-' x $TERM_WIDTH;
say 'PARSED:';
say '-' x $TERM_WIDTH;
say $alloc->Util->DUMP($_) foreach @$parsed;
say '=' x $TERM_WIDTH;
say '';
say '=' x $TERM_WIDTH;
say 'COMPILIER LOG:';
say '-' x $TERM_WIDTH;
$alloc->Str("BEFORE COMPILING");
my ($compiled, $e) = $c->compile( $parsed, $bif );
say '-' x $TERM_WIDTH;
say 'COMPILED:';
say '-' x $TERM_WIDTH;
say $alloc->Util->DUMP($_) foreach @$compiled;
say '=' x $TERM_WIDTH;

if ($ENV{AST}) {
    $alloc->Str("BEFORE AST RUNTIME");
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
    say $alloc->Util->DUMP($evaled);
    say '=' x $TERM_WIDTH;
}

if ($ENV{CEK}) {
    $alloc->Str("BEFORE CEK RUNTIME");
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
    say $alloc->Util->DUMP($evaled);
    say '=' x $TERM_WIDTH;
}

$alloc->Str("THE END");

if ($ENV{STATS}) {
    say '';
    say '=' x $TERM_WIDTH;
    say 'STATS:';
    say '-' x $TERM_WIDTH;
    my $stats = $alloc->stats;

    my $total_requests       = $stats->{total_requests};
    my $total_fulfilled      = $stats->{total_fulfilled};
    my $requested_by_hash = $stats->{requested_by_hash};
    my $created_by_type   = $stats->{created_by_type};

    say sprintf '  total_requests : %d' => $total_requests;
    say sprintf '  total_created  : %d' => $total_fulfilled;
    say sprintf '  total created  : (by type)';
    my @sorted_types = sort { $created_by_type->{$b} <=> $created_by_type->{$a} } keys $created_by_type->%*;
    say '    +-----------+----------+';
    say '    | type      | count    |';
    say '    +-----------+----------+';
    foreach my $key (@sorted_types) {
        say sprintf '    | %-9s | %-8d |', $key, $created_by_type->{$key};
    }
    say '    +-----------+----------+';
    say sprintf '  top-K requests : (by hash)';
    my $filtered = 0;
    my @sorted_hashes =
        map {
            if ($requested_by_hash->{$_} < 10) {
                $filtered++;
                ();
            } else {
                $_
            }
        }
        sort { $requested_by_hash->{$b} <=> $requested_by_hash->{$a} }
        keys $requested_by_hash->%*;
    say '    +--------+----------+';
    say '    | hash   | count    |';
    say '    +--------+----------+';
    foreach my $hash (@sorted_hashes) {
        say sprintf '    | %s | %-8d | %s', substr($hash, 0, 6), $requested_by_hash->{$hash}, substr($alloc->Util->pprint($alloc->deref_hash($hash)), 0, $TERM_WIDTH - 26);
    }
    say         '    +--------+----------+';
    say sprintf '    |  < 10  | %-8d |' => $filtered;
    say         '    +--------+----------+';
    say '=' x $TERM_WIDTH;
}

if ($ENV{DUMP_MEMORY}) {
    say '';
    say '=' x $TERM_WIDTH;
    say 'MEMORY:';
    say '-' x $TERM_WIDTH;
    say $alloc->Util->DUMP($_) foreach $alloc->memory;
    say '=' x $TERM_WIDTH;
}

## -----------------------------------------------------------------------------

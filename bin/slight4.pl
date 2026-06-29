use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];
use Data::Dumper qw[ Dumper ];

use constant DEBUG => $ENV{DEBUG} // 0;
use Term::ReadKey (); our $TERM_WIDTH = (Term::ReadKey::GetTerminalSize)[0];

use Digest::MD5 ();

## -----------------------------------------------------------------------------

class Term {
    field $index :param :reader;
    field $data  :param :reader;
    method is_nil { false }
    method is_equal_to ($o) { $index->hash == $o->index->hash }
}

class Sym     :isa(Term) { method ident { $self->data->[0] } }
class Str     :isa(Term) { method value { $self->data->[0] } }
class Num     :isa(Term) { method value { $self->data->[0] } }
class Bool    :isa(Term) { method value { $self->data->[0] } }
class Nil     :isa(Term) { method is_nil { true } }
class Cons    :isa(Term) {
    method head { $self->data->[0] }
    method tail { $self->data->[1] }
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
}

## -----------------------------------------------------------------------------

class Allocator::Env::Util {
    field $alloc :param :reader;

    method init_env (@bindings) {
        my $env = $alloc->Nil;
        foreach my ($sym, $val) (@bindings) {
            $env = $alloc->Env( $alloc->Pair( $sym, $val ), $env );
        }
        return $env;
    }

    method bind_symbol ($sym, $val, $env) {
        $alloc->Env( $alloc->Pair( $sym, $val ), $env )
    }

    method bind_params ($params, $args, $env) {
        my @params = $alloc->Lists->uncons($params);
        my @args   = $alloc->Lists->uncons($args);
        die sprintf 'Arity mismatch, got(%s) expected(%s)' => (scalar @args), (scalar @params)
            unless scalar @args == scalar @params;
        my $local = $env;
        while (@params) {
            $local = $self->bind_symbol( shift @params, shift @args, $local )
        }
        return $local;
    }
}

class Allocator::List::Util {
    field $alloc :param :reader;

    method list_of (@list) {
        my $list = $alloc->Nil;
        while (@list) {
            $list = $alloc->Cons( pop @list, $list );
        }
        return $list;
    }

    method uncons ($list) {
        my @list;
        until ($list->is_nil) {
            push @list => $alloc->deref( $list->head );
            $list = $alloc->deref( $list->tail );
        }
        return @list;
    }
}

class Allocator::Util {
    field $alloc :param :reader;

    method pprint ($t) {
        given (blessed $t) {
            when ('Sym')    { $t->ident }
            when ('Str')    { $t->value }
            when ('Num')    { $t->value }
            when ('Bool')   { $t->value }
            when ('Nil')    { '#nil' }
            when ('Cons')   { sprintf '(%s)' => join ' ' => map $self->pprint($_), $alloc->Lists->uncons($t) }
            when ('Pair')   { sprintf '(%s . %s)' => $self->pprint($alloc->deref($t->first)), $self->pprint($alloc->deref($t->second)) }
            when ('Env')    { sprintf '{ %s }' => join ' ' => map $self->pprint($_), $alloc->Lists->uncons($t) }
            when ('Lambda') {
                sprintf '(<lambda> %s %s)' =>
                    $self->pprint($alloc->deref($t->params)),
                    $self->pprint($alloc->deref($t->body))
            }
            default { die "WTF! $self" }
        }
    }

    method DUMP ($t) {
        sprintf(
            '$(%05d) | %-6s | %s | %-26s | %s',
            $t->index->idx,
            (blessed $t),
            (substr $t->index->hash, 0, 6),
            (join ' ' => map {
                blessed $_
                    ? (sprintf '$(%05d)' => $_->idx)
                    : (length $_ > 22 ? (substr($_, 0, 22).' ...') : $_)
            } $t->data->@*),
            $self->pprint($t)
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

    field $Nil;
    field $True;
    field $False;

    field $Utils :reader;
    field $Lists :reader;
    field $Envs  :reader;

    method deref ($index) { $memory[ $index->idx ] }

    my method intern ($type, @payload) {
        my $hash  = Digest::MD5::md5_hex( join '/' => $type, join ':' => @payload );
        return $memory[ $intern{ $hash }->idx ] if exists $intern{ $hash };
        my $index = Index->new( idx => (scalar @memory), hash => $hash );
        my $value = $type->new(
            index => $index,
            data  => [ map blessed $_ ? $_->index : $_, @payload ]
        );
        push @memory => $value;
        $intern{$hash} = $index;
        return $value;
    }

    ADJUST {
        $Nil   = $self->&intern( Nil  => '#nil'   );
        $True  = $self->&intern( Bool => '#true'  );
        $False = $self->&intern( Bool => '#false' );

        $Utils = Allocator::Util->new( alloc => $self );
        $Lists = Allocator::List::Util->new( alloc => $self );
        $Envs  = Allocator::Env::Util->new( alloc => $self );
    }

    method Nil   { $Nil }
    method True  { $True }
    method False { $False }

    method Bool   ($value)     { $value ? $True : $False }
    method Sym    ($ident)     { $self->&intern( Sym  => $ident ) }
    method Num    ($value)     { $self->&intern( Num  => $value ) }
    method Str    ($value)     { $self->&intern( Str  => $value ) }
    method Cons   ($h, $t)     { $self->&intern( Cons => $h, $t ) }
    method Pair   ($f, $s)     { $self->&intern( Pair => $f, $s ) }
    method Env    ($p, $r)     { $self->&intern( Env  => $p, $r ) }
    method Lambda ($p, $b, $e) { $self->&intern( Lambda  => $p, $b, $e ) }
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
            when (')')     { $self->push_stack( $alloc->Lists->list_of( @{ pop @tokens } ) ) }
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

    field @environs;

    method compile ($exprs, $env=undef) {
        push @environs => ($env //= $alloc->Envs->init_env);
        return +[ map $self->compile_expr($_), @$exprs ]
    }

    method compile_expr ($expr) {
        if ($expr isa Cons) {
            my $h = $alloc->deref( $expr->head );
            my $t = $alloc->deref( $expr->tail );
            if ($h isa Sym) {
                given ($h->ident) {
                    when ('lambda') {
                        my ($p, $b) = $alloc->Lists->uncons($t);
                        return $alloc->Lambda( $p, $b, $environs[-1] );
                    }
                    when ('defun') {
                        my ($name, $p, $b) = $alloc->Lists->uncons($t);
                        my $env    = $environs[-1];
                        my $lambda = $alloc->Lambda( $p, $b, $env );
                        push @environs => $alloc->Envs->bind_symbol( $name, $lambda, $env );
                        return $alloc->deref( $environs[-1]->head ); # return the pair binding ...
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

my $a = Allocator->new;
my $p = Parser->new( alloc => $a );
my $c = Compiler->new( alloc => $a );

my $parsed = $p->parse(q[

    (lambda (x y) (+ x y))
    (defun adder (x y) (+ x y))

]);

my $compiled = $c->compile( $parsed );

say 'PARSED:';
say $a->Utils->DUMP($_) foreach @$parsed;
say 'COMPILED:';
say $a->Utils->DUMP($_) foreach @$compiled;
say 'MEMORY:';
say $a->Utils->DUMP($_) foreach $a->memory;

## -----------------------------------------------------------------------------

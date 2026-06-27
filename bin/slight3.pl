use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];
use Data::Dumper qw[ Dumper ];

package Term {
    sub is_nil ($)     { false }
    sub type   ($self) { $self->[0] }
    sub data   ($self) { $self->[1] }
    sub pprint ($self) {
        given ($self->type) {
            when ('Sym')    { $self->ident }
            when ('Str')    { '"'.$self->value.'"' }
            when ('Num')    { $self->value }
            when ('Bool')   { $self->value ? '#true' : '#false' }
            when ('Nil')    { '()' }
            when ('Cons')   { sprintf '(%s)' => join ' ' => map { $_->pprint } $self->uncons }
            when ('Pair')   { sprintf '<%s . %s>' => $self->fst->pprint, $self->snd->pprint }
            default { die "Cannot ->pprint a (".(join ', ' => @$self).")" }
        }
    }
}

package Term::Sym   { our @ISA; BEGIN { @ISA = ('Term') }
    sub ident ($self) { $self->data->[0] }
}
package Term::Bool  { our @ISA; BEGIN { @ISA = ('Term') }
    sub value ($self) { $self->data->[0] }
}
package Term::Num   { our @ISA; BEGIN { @ISA = ('Term') }
    sub value ($self) { $self->data->[0] }
}
package Term::Str   { our @ISA; BEGIN { @ISA = ('Term') }
    sub value ($self) { $self->data->[0] }
}
package Term::Pair  { our @ISA; BEGIN { @ISA = ('Term') }
    sub fst ($self) { $self->data->[0] }
    sub snd ($self) { $self->data->[1] }
}
package Term::Nil  { our @ISA; BEGIN { @ISA = ('Term') }
    sub is_nil ($) { true }
}
package Term::Cons  { our @ISA; BEGIN { @ISA = ('Term') }
    sub head   ($self) { $self->data->[0] }
    sub tail   ($self) { $self->data->[1] }
    sub uncons ($self) { $self->head, ($self->tail->is_nil ? () : $self->tail->uncons) }
}

sub Term  ($t, @p)     { bless [ $t => \@p ] => 'Term::'.$t }

sub Sym   ($s)         { Term(Sym  => $s) }
sub Bool  ($b)         { Term(Bool => $b) }
sub Num   ($n)         { Term(Num  => $n) }
sub Str   ($s)         { Term(Str  => $s) }
sub True  ()           { Bool(true)  }
sub False ()           { Bool(false) }
sub Nil   ()           { Term('Nil') }
sub Pair  ($f, $s)     { Term(Pair => $f, $s) }
sub Cons  ($h, $t=Nil) { Term(Cons => $h, $t) }

sub List (@items) {
    my $list = Nil;
    $list = Cons(pop @items, $list) while @items;
    return $list;
}

sub isSym     ($t) { $t->type eq 'Sym' }
sub isBool    ($t) { $t->type eq 'Bool' }
sub isNum     ($t) { $t->type eq 'Num'  }
sub isStr     ($t) { $t->type eq 'Str'  }
sub isTrue    ($t) { $t->type eq 'Bool' && $t->value }
sub isFalse   ($t) { $t->type eq 'Bool' && !$t->value }
sub isNil     ($t) { $t->type eq 'Nil' }
sub isCons    ($t) { $t->type eq 'Cons' }
sub isPair    ($t) { $t->type eq 'Pair' }

sub isLiteral ($t) { isNum($t) || isStr($t) || isBool($t) }

sub Tag ($tag, $body) { Pair( Sym($tag), $body ) }

sub isTagged ($t) { isPair($t) && isSym($t->fst) }

sub RETURN ($value)       { Tag(RETURN => $value) }
sub LOOKUP ($symbol)      { Tag(LOOKUP => $symbol) }
sub EHEAD  ($list)        { Tag(EHEAD  => $list) }
sub EARGS  ($list, $done) { Tag(EARGS  => Pair($list, $done)) }
sub APPLY  ($call)        { Tag(APPLY  => $call) }

sub isRETURN ($e) { isTagged($e) && $e->fst->ident eq 'RETURN' }
sub isLOOKUP ($e) { isTagged($e) && $e->fst->ident eq 'LOOKUP' }
sub isEHEAD  ($e) { isTagged($e) && $e->fst->ident eq 'EHEAD'  }
sub isEARGS  ($e) { isTagged($e) && $e->fst->ident eq 'EARGS'  }
sub isAPPLY  ($e) { isTagged($e) && $e->fst->ident eq 'APPLY'  }

class Parser {
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
            when (')')     { $self->push_stack( ::List( @{ pop @tokens } ) ) }
            when (/[0-9]/) { $self->push_stack( ::Num( $self->parse_number( $next ) ) ) }
            when ('"')     { $self->push_stack( ::Str( $self->parse_string( $next ) ) ) }
            when ('-')     { $self->peek =~ /[0-9]/
                ? $self->push_stack( ::Num( $self->parse_number( $next ) ) )
                : $self->push_stack( ::Sym( $self->parse_symbol( $next ) ) )
            }
            when ('#') {
                given ($self->peek) {
                    when ('t') { $self->advance; $self->push_stack( ::True ) }
                    when ('f') { $self->advance; $self->push_stack( ::False ) }
                    when ('n') { $self->advance; $self->push_stack( ::Nil ) }
                    default {
                        $self->push_stack( ::Sym( $self->parse_symbol( $next ) ) );
                    }
                }
            }
            default {
                $self->push_stack( ::Sym( $self->parse_symbol( $next ) ) );
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

sub compile ($expr) {
    say $expr->pprint;

    unless (isTagged($expr)) {
        return RETURN( $expr )           if isLiteral($expr);
        return LOOKUP( $expr )           if isSym($expr);
        return compile( EHEAD( $expr ) ) if isCons($expr);
        die "WTF! ".$expr->pprint;
    }

    if (isEHEAD($expr)) {
        my $list = $expr->snd;
        return compile( EARGS( Cons( compile( $list->head ), Nil), $list->tail ) )
    }
    elsif (isEARGS($expr)) {
        my $done = $expr->snd->fst;
        my $rest = $expr->snd->snd;
        if (isNil($rest)) {
            return compile( APPLY( $done ) )
        }
        else {
            return compile( EARGS( Cons( compile( $rest->head ), $done ), $rest->tail ) )
        }
    }
    elsif (isAPPLY($expr)) {
        return $expr;
    }
    else {
        die "WTF! is ".$expr->pprint;
    }
}

my $p = Parser->new;

my ($expr) = $p->parse(q[
    (+ 10 (* 4 5))
])->@*;


say 'parsed: ', $expr->pprint;
say compile($expr)->pprint;




use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Slight;

use Slight::Tools::TUI;
use Caroline;

my %PALETTE = %Slight::Tools::TUI::PALETTE;

BEGIN {
    *ITALIC = \&Slight::Tools::TUI::ITALIC;
    *BOLD   = \&Slight::Tools::TUI::BOLD;
    *UNDERLINE = \&Slight::Tools::TUI::UNDERLINE;
    *FG = \&Slight::Tools::TUI::FG;
    *BG = \&Slight::Tools::TUI::BG;
}

my $screen = Slight::Tools::TUI::Screen->new;
$screen->init;
$screen->inline(
    Slight::Tools::TUI::Text->with(
        Slight::Tools::TUI::Style->as(ITALIC),
        Slight::Tools::TUI::Style->as(FG($PALETTE{urobilinYellow})),   'Slight',
        Slight::Tools::TUI::Style->as(FG($PALETTE{antiqueWhite})),   ' ┅ ',
        Slight::Tools::TUI::Style->as(FG($PALETTE{raspberryPink})),   'R',
        Slight::Tools::TUI::Style->as(FG($PALETTE{electricLime})),    'E',
        Slight::Tools::TUI::Style->as(FG($PALETTE{babyBlueEyes})),    'P',
        Slight::Tools::TUI::Style->as(FG($PALETTE{twilightLavender})),'L',
    )
);

$screen->at(
    [ 1, $screen->width - 40 ],
    Slight::Tools::TUI::Text->with(
        Slight::Tools::TUI::Style->as(BG($PALETTE{airSuperiorityBlue}), BOLD, UNDERLINE),
        sprintf '%-40s' => ' HISTORY:'
    )
);

my $prompt = Slight::Tools::TUI::Text->with(
    Slight::Tools::TUI::Style->as(FG($PALETTE{acidGreen})),
    '? '
)->render;

my $r = Slight::Runtime->new->init;
my $context = $r->spawn_context('(defun help () (say "HELLO!"))');
$r->run;

my $c = Caroline->new( history_max_len => $screen->height - 1 );
$screen->line_break;
while (true) {
    my $input = $c->readline($prompt);

    if ($input eq ':q') {
        last;
    }

    try {
        my ($expr) = $r->parse_source($input);

        $context = $r->fork_context( $context, +[ $expr ], $context->last_env );

        $r->run;

        $screen->inline(
            Slight::Tools::TUI::Text->with(
                Slight::Tools::TUI::Style->as(FG($PALETTE{yellowGreen}), BOLD),
                '> '.($context->result // $context->error)
            )
        );

        $c->history_add($input);
    } catch ($e) {
        $screen->inline(
            Slight::Tools::TUI::Text->with(
                Slight::Tools::TUI::Style->as(FG($PALETTE{persimmonOrange}), BOLD),
                "! ${e}"
            )
        );
    }

    my @history = $c->history->@*;
    $screen->line_break;
    $screen->at(
        [ 2, $screen->width - 40 ],
        Slight::Tools::TUI::TextArea->new(
            style    => Slight::Tools::TUI::Style->as(BG($PALETTE{airSuperiorityBlue})),
            contents => +[ map { sprintf ' %s' => $_ } @history ],
            height   => (scalar @history),
            width    => 40,
        )
    );
}

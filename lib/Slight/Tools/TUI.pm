package Slight::Tools::TUI;

use v5.42;
use utf8;
use open ':std', ':encoding(UTF-8)';
use experimental qw[ class switch ];

use Term::ReadKey qw[ GetTerminalSize ReadMode ];
use Time::HiRes   qw[ time ];

# Terminal setup

sub get_terminal_size { GetTerminalSize() }

sub clear_screen { "\e[2J" }

sub hide_cursor  { "\e[?25l" }
sub show_cursor  { "\e[?25h" }

sub enable_alt_buf  { "\e[?1049h" }
sub disable_alt_buf { "\e[?1049l" }

# Cursor

sub home_cursor  { "\e[H" }

sub format_move_cursor   (@to) { sprintf "\e[%d;%dH"  => @to    }

sub format_line_break ($width) { sprintf "\e[B\e[%dD" => $width }

sub format_move_up    ($by) { sprintf "\e[%dA"  => $by }
sub format_move_down  ($by) { sprintf "\e[%dB"  => $by }
sub format_move_left  ($by) { sprintf "\e[%dD"  => $by }
sub format_move_right ($by) { sprintf "\e[%dC"  => $by }

# Input Read-Mode

sub restore_read_mode       ($fh=*STDIN) { ReadMode restore => $fh }
sub set_read_mode_to_normal ($fh=*STDIN) { ReadMode normal  => $fh }
sub set_read_mode_to_noecho ($fh=*STDIN) { ReadMode noecho  => $fh }
sub set_read_mode_to_raw    ($fh=*STDIN) { ReadMode cbreak  => $fh }

# Style/Color utilities

our %PALETTE;

# NOTE:
# default FG = 39, default BG = 49

sub FG (@rgb) { 38, 2, ref $rgb[0] ? $rgb[0]->@* : @rgb }
sub BG (@rgb) { 48, 2, ref $rgb[0] ? $rgb[0]->@* : @rgb }

use constant BOLD      => 1;
use constant FAINT     => 2;
use constant ITALIC    => 3;
use constant UNDERLINE => 4;
use constant INVERT    => 7;
use constant HIDE      => 8;
use constant STRIKE    => 9;

use constant NORMAL        => 22;
use constant NOT_ITALIC    => 23;
use constant NOT_UNDERLINE => 24;
use constant NOT_INVERT    => 27;
use constant NOT_HIDE      => 28;
use constant NOT_STRIKE    => 29;

sub clear_styles           { "\e[0m" }
sub apply_styles (@styles) { sprintf "\e[%s;m" => join ';' => @styles }

sub hex2rgb ($hex) { +[ map hex, (substr($hex, 0, 2), substr($hex, 2, 2), substr($hex, 4, 2)) ] }


say apply_styles(
    FG( $PALETTE{goldenPoppy} ),
    BG( $PALETTE{deepCerulean} ),
    BOLD,
);
say " Hello World ";
say apply_styles(UNDERLINE), " Goodbye All ";
say apply_styles(NORMAL, NOT_UNDERLINE, ITALIC), "... hmm ";
say clear_styles;

## -----------------------------------------------------------------------------
## Static data below ...
## -----------------------------------------------------------------------------

BEGIN {
    %PALETTE = (
        cardinalRed          => hex2rgb("C41E3A"),
        deepCerulean         => hex2rgb("007BA7"),
        electricLime         => hex2rgb("CCFF00"),
        fuchsiaRose          => hex2rgb("C74375"),
        goldenPoppy          => hex2rgb("FCC200"),
        heliotropePurple     => hex2rgb("DF73FF"),
        irisBlue             => hex2rgb("5A4FCF"),
        jadeGreen            => hex2rgb("00A86B"),
        kellyGreen           => hex2rgb("4CBB17"),
        lapisLazuli          => hex2rgb("26619C"),
        mardiGras            => hex2rgb("880085"),
        neonCarrot           => hex2rgb("FFA343"),
        operaMauve           => hex2rgb("B784A7"),
        persianBlue          => hex2rgb("1C39BB"),
        quinacridoneMagenta  => hex2rgb("8E3A59"),
        raspberryPink        => hex2rgb("E25098"),
        sapphireBlue         => hex2rgb("0F52BA"),
        tangerineYellow      => hex2rgb("FFCC00"),
        ultramarineBlue      => hex2rgb("3F00FF"),
        venetianRed          => hex2rgb("C80815"),
        wengeWood            => hex2rgb("645452"),
        xanaduGreen          => hex2rgb("738678"),
        yellowGreen          => hex2rgb("9ACD32"),
        zaffreBlue           => hex2rgb("0014A8"),
        amaranthPink         => hex2rgb("F19CBB"),
        byzantiumPurple      => hex2rgb("702963"),
        coquelicotOrange     => hex2rgb("FF3800"),
        dandelionYellow      => hex2rgb("F0E130"),
        emeraldGreen         => hex2rgb("50C878"),
        flaxFlowerBlue       => hex2rgb("1C3B2B"),
        ghostWhite           => hex2rgb("F8F8FF"),
        hollywoodCerise      => hex2rgb("F400A1"),
        indigoDye            => hex2rgb("00416A"),
        jasmineFlower        => hex2rgb("F8DE7E"),
        keppelColor          => hex2rgb("3AB09E"),
        libertyPurple        => hex2rgb("545AA7"),
        moonstoneBlue        => hex2rgb("73A9C2"),
        nadeshikoPink        => hex2rgb("F6ADC6"),
        outerSpaceBlack      => hex2rgb("414A4C"),
        persimmonOrange      => hex2rgb("EC5800"),
        quickSilver          => hex2rgb("A6A6A6"),
        razzmatazzPink       => hex2rgb("E3256B"),
        sunglowYellow        => hex2rgb("FFCC33"),
        twilightLavender     => hex2rgb("8A496B"),
        urobilinYellow       => hex2rgb("E1AD21"),
        violetColor          => hex2rgb("7F00FF"),
        waterspoutBlue       => hex2rgb("A4F4F9"),
        xanthicYellow        => hex2rgb("EEED09"),
        yaleBlue             => hex2rgb("0F4D92"),
        zompGreen            => hex2rgb("39A78E"),
        absoluteZero         => hex2rgb("0048BA"),
        acidGreen            => hex2rgb("B0BF1A"),
        aero                 => hex2rgb("7CB9E8"),
        africanViolet        => hex2rgb("B284BE"),
        airSuperiorityBlue   => hex2rgb("72A0C1"),
        alabaster            => hex2rgb("EDEAE0"),
        aliceBlue            => hex2rgb("F0F8FF"),
        alloyOrange          => hex2rgb("C46210"),
        almond               => hex2rgb("EFDECD"),
        amaranth             => hex2rgb("E52B50"),
        amber                => hex2rgb("FFBF00"),
        amethyst             => hex2rgb("9966CC"),
        antiqueBrass         => hex2rgb("CD9575"),
        antiqueBronze        => hex2rgb("665D1E"),
        antiqueRuby          => hex2rgb("841B2D"),
        antiqueWhite         => hex2rgb("FAEBD7"),
        aoEnglish            => hex2rgb("008000"),
        appleGreen           => hex2rgb("8DB600"),
        apricot              => hex2rgb("FBCEB1"),
        aqua                 => hex2rgb("00FFFF"),
        aquamarine           => hex2rgb("7FFFD4"),
        arcticLime           => hex2rgb("D0FF14"),
        armyGreen            => hex2rgb("4B5320"),
        artichoke            => hex2rgb("8F9779"),
        arylideYellow        => hex2rgb("E9D66B"),
        ashGray              => hex2rgb("B2BEB5"),
        asparagus            => hex2rgb("87A96B"),
        atomicTangerine      => hex2rgb("FF9966"),
        auburn               => hex2rgb("A52A2A"),
        aureolin             => hex2rgb("FDEE00"),
        avocado              => hex2rgb("568203"),
        azure                => hex2rgb("007FFF"),
        babyBlue             => hex2rgb("89CFF0"),
        babyBlueEyes         => hex2rgb("A1CAF1"),
        babyPink             => hex2rgb("F4C2C2"),
        babyPowder           => hex2rgb("FEFEFA"),
        bakerMillerPink      => hex2rgb("FF91AF"),
        bananaMania          => hex2rgb("FAE7B5"),
        barbiePink           => hex2rgb("DA1884"),
        barnRed              => hex2rgb("7C0A02"),
        battleshipGrey       => hex2rgb("848482"),
        bazaar               => hex2rgb("98777B"),
        beauBlue             => hex2rgb("BCD4E6"),
        beaver               => hex2rgb("9F8170"),
        begonia              => hex2rgb("FA6E79"),
        beige                => hex2rgb("F5F5DC"),
    );

}

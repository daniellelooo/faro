#!/usr/bin/perl
# Carga el adaptador de "Ahora suena" de Dicta dentro de perl (binario de Apple) y ejecuta el modo pedido.
# Uso: /usr/bin/perl now-playing.pl <libDictaNowPlaying.dylib> [get|watch]
use strict;
use warnings;
use DynaLoader;
$| = 1;
my ($library, $mode) = @ARGV;
$mode //= "get";
my %entries = (get => "dicta_now_playing_get", watch => "dicta_now_playing_watch");
die "now-playing: modo desconocido\n" unless exists $entries{$mode};
my $handle = DynaLoader::dl_load_file($library, 0) or die "now-playing: " . DynaLoader::dl_error() . "\n";
my $symbol = DynaLoader::dl_find_symbol($handle, $entries{$mode}) or die "now-playing: " . DynaLoader::dl_error() . "\n";
DynaLoader::dl_install_xsub("main::dicta_now_playing_run", $symbol);
dicta_now_playing_run();

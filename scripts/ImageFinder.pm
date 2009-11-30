#!/usr/bin/perl
#
# Copyright (C) 2007 Peteris Krumins (peter@catonmat.net)
# http://www.catonmat.net  -  good coders code, great reuse
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#

package ImageFinder;

#
# This package was written as a part of "reddit media: intelligent fun online"
# website generator.
# This website can be viewed here: http://redditmedia.com 
#
# See http://www.catonmat.net/designing-reddit-media-website for more info.
#

use warnings;
use strict;

#
# This module find "best" image on a web page.
# Since this package was written for purpose of redditmedia.com website,
# the "best" means a picture which is most likely to be posted on the site
# for others to enjoy.
#
# People enjoy big pictures, so this package finds the image on a webpage which
# has biggest area (width * height).
#

use File::Temp 'mktemp';
use LWP::UserAgent;
use HTML::TreeBuilder;
use URI;

use NetPbm;

sub new {
    my $this = shift;
    my $class = ref($this) || $this;
    my %args = @_;

    my $self;
    $self->{netpbm} = NetPbm->new(netpbm => $args{'netpbm'});
    $self->{ua} = LWP::UserAgent->new(
        agent => 'Mozilla/5.0 (Windows; U; Windows NT 5.1; en-US) Gecko/20070515 Firefox/2.0.0.4'
    );

    bless $self, $this;
}

#
# find_best_image
#
# Given a URL address to a website, the function gets all the images on the page
# and figures out which one is the best. 
#
sub find_best_image {
    my ($self, $url) = @_;

    my $content = $self->_get_page($url);
    return undef unless defined $content;

    my $tree = HTML::TreeBuilder->new;
    $tree->parse($content);

    # find all img tags
    my @imgs = $tree->look_down(_tag => 'img');
    unless (@imgs) {
        $tree->delete;
        return undef
    }

    # download all images
    my @downloaded_images;
    foreach my $img (@imgs) {
        my $src = $img->attr('src'); # could be relative path, fix
        next unless $src;

        my $abs_src = URI->new_abs($src, $url)->as_string;

        my $tmp_file = $self->_get_temp_file;
        my $resp = $self->{ua}->get($abs_src, ":content_file" => $tmp_file);
        next unless $resp->is_success;

        unless (-s $tmp_file) { # skip empty files
            unlink $tmp_file;
            next;
        }
        push @downloaded_images, $tmp_file;
    }

    return undef unless @downloaded_images; # huh, no images?

    return $self->_biggest_image(@downloaded_images);
}

#
# _biggest_image
#
# Given a list of images, finds the biggest image (width * height maximum)
#
sub _biggest_image {
    my ($self, @images) = @_;

    my $netpbm = $self->{netpbm};
    # convert all images to PNM format
    my @pnms;
    foreach (@images) {
        my $pnm_file = $netpbm->img2pnm($_);
        unlink $_;
        if ($netpbm->is_error) {
            print STDERR $netpbm->get_error, "\n";
            $netpbm->clear_error;
            next;
        }
        push @pnms, $pnm_file;
    }

    my @img_infos;
    foreach (@pnms) {
        my %info = $netpbm->get_img_info($_);
        if ($netpbm->is_error) {
            print STDERR $netpbm->get_error, "\n";
            $netpbm->clear_error;
            next;
        }
        push @img_infos, {
            info => \%info,
            path => $_
        };
    }

    my @sorted_by_area = sort {
        $b->{info}{width} * $b->{info}{height} <=> $a->{info}{width} * $a->{info}{height}
    } @img_infos;

    unlink $_->{path} foreach @sorted_by_area[1..$#sorted_by_area];

    return $sorted_by_area[0]->{path};
}

sub _get_page {
    my ($self, $url) = @_;
    my $resp = $self->{ua}->get($url);

    if ($resp->is_success) {
        return $resp->content;
    }
    return undef;
}

# 
# _get_temp_file
#
# Creates and returns the path to a new temporary file
#
sub _get_temp_file {
    return mktemp("/tmp/imageIFXXXXXXXX");
}

1;

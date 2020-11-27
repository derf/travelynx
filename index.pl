#!/usr/bin/env perl
# Copyright (C) 2020 Daniel Friesel
#
# SPDX-License-Identifier: MIT

use strict;
use warnings;

use lib 'lib';
use Mojolicious::Commands;

Mojolicious::Commands->start_app('Travelynx');

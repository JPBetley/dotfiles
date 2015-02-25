#!/bin/sh
#
# PHP
#
# This installs some of the common dependencies needed (or at least desired)
# using PHP/Composer.

# Check for PHP
if test ! $(which php)
then
  echo "  Tapping dependencies for PHP."
  brew tap homebrew/dupes
  brew tap homebrew/versions
  brew tap homebrew/homebrew-php
  brew install freetype jpeg libpng gd zlib openssl unixodbc

  echo "  Installing PHP for you."
  brew install php55
fi

# Check for Composer
if test ! $(which composer)
then
  echo "  Installing composer."
  curl -sS https://getcomposer.org/installer | php -- --install-dir=".bin"
fi
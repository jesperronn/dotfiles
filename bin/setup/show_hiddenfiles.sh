#!/bin/sh
# show_hiddenfiles.sh — make Finder show hidden files via the AppleShowAllFiles default.
#tip from http://www.tech-recipes.com/rx/3104/os-x-show-hidden-files-and-folders-in-mac-os-x-finder/
defaults write com.apple.finder AppleShowAllFiles TRUE

# to invert type 
#defaults write com.apple.finder AppleShowAllFiles FALSE
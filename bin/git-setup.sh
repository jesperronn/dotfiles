#!/bin/bash
# git-setup.sh — prompts for your name and email and sets them as global git user config.
#git-setup
#from http://rails.wincent.com/wiki/Git_quickstart
#modified by Jesper Rønn-Jensen to take interactive input

echo "Your name: "
read -r NAME
echo "Your email: "
read -r EMAIL

# personalize these with your own name and email address
git config --global user.name "$NAME"
git config --global user.email "$EMAIL"

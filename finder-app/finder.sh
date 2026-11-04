#!/bin/sh

#check if exactly two arguments are provided
if [ "$#" -ne 2 ]; then
    echo "Error: Exactly two arguments are required."
    echo "Usage: $0 <filesdir> <searchstr>"
    exit 1
fi

#set variables for the arguments
FILESDIR=$1
SEARCHSTR=$2

#check if the first argument is a valid directory
if [ ! -d "$FILESDIR" ]; then
    echo "Error: filesdir does not exist or is not a directory: $FILESDIR"
    exit 1
fi

#find the number of files and the number of matching lines
NUMFILES=$(find "$FILESDIR" -type f | awk 'END {print NR}')
NUMLINES=$(grep -r -F -h -- "$SEARCHSTR" "$FILESDIR" | wc -l | tr -d ' ')

#output message
echo "The number of files are $NUMFILES and the number of matching lines are $NUMLINES"
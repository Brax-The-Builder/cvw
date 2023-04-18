#!/bin/bash

# okstate.sh
# james.stine@okstate.edu 26 March 2023
# Set up tools for rvw
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

echo "Executing Wally OSU setup sh"

alias rm="rm -i"
alias mv="mv -i"
alias cp="cp -i"

export MODSIM=/opt/ModelSim/questasim
export PATH=$PATH:$MODSIM/bin
export LD_LIBRARY_PATH=/usr/lib:/lib
export MGC_DOC_PATH=$MODSIM/docs
export MGC_PDF_READER=evince
export MGC_HTML_BROWSER=firefox
export MGLS_LICENSE_FILE=1717@trelaina.ecen.okstate.edu
export IMPERASD_LICENSE_FILE=2700@trelaina.ecen.okstate.edu
export EDITOR=emacs

echo "Oklahoma State setup done"

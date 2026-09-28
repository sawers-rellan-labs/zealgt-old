#!/bin/bash
# Laptop-side: wait <min> minutes (default 8), then print the Gate 1 progress from hazel.
sleep $(( ${1:-8} * 60 ))
ssh hazel 'bash -s' < /Users/fvrodriguez/repos/zealgt/agent/20260928_211000_progress_gate1.sh

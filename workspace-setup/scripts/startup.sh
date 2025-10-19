#!/usr/bin/env bash
echo "---------------- WORKSPACE SETUP --------------"
echo "                    SETUP                      "
echo "-----------------------------------------------"

ls -alh /wrk
touch /wrk/workspace-setup.done
echo "Ready to have fun :)"
env


echo "Pod Name=$POD_NAME"
# Kubernetes appends a 5-character hash to pod names (e.g., pod-name-a1b2c)
# Remove the last 6 characters (dash + 5-char hash) using parameter expansion
JOB_NAME="${POD_NAME%-?????}"
echo "Job Submitted=$JOB_NAME"

#!/bin/bash
# ProjectBW compatibility start script.
# Deliberately does not modify AutoPlug configuration.

set -e
cd /mnt/server
exec java -Xms128M -Xmx500M -Dterminal.jline=false -Dterminal.ansi=true -jar AutoPlug-Client.jar

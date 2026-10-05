mkdir bin
touch bin/config.toml
printf "title=\"chat_server\"\n\n[whitelist]\nenabled=true\nallowed_clients=[]\nbanned_clients=[]\n" > bin/config.toml

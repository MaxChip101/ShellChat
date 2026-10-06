mkdir bin
touch bin/config.toml
printf "title=\"chat_server\"
whitelisted_clients=[] # {username = \"username\", fingerprint = \"fingerprint\"}
" > bin/config.toml

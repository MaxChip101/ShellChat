mkdir bin
touch bin/config.toml
printf "title=\"chat_server\"
whitelisted_clients=[] # {username=\"username\",fingerprint=\"fingerprint\"}
host=\"0.0.0.0\" # open to all addresses
port=2222 # default port
" > bin/config.toml

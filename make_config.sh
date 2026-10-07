mkdir bin
touch bin/config.toml
printf "title=\"chat_server\"
host=\"0.0.0.0\" # open to all addresses
port=2222 # default port
whitelisted_clients=[] # {username=\"username\",rank=0,fingerprint=\"fingerprint\"} # rank is a number between 0-255

channels = [
    {
        name=\"general\",
        type=\"chat\",
        permissions=[
            {name=\"view\",rank=0},
            {name=\"chat\",rank=25},
            {name=\"edit\",rank=50},
            {name=\"manage\",rank=200},
        ]
    }
]

" > bin/config.toml

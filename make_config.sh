mkdir bin
touch bin/init.lua
printf "server.title = "chat_server"
server.host = \"0.0.0.0\" -- open to all addresses
server.port = 2222 -- default port

function test(client_id, command, args)
    _ = client_id
    _ = args
    print(\"test done\")
    print(command)
end

server.registerCommand(\"/test\", test)
" > bin/init.lua

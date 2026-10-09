mkdir bin
touch bin/init.lua
printf "server.title = "chat_server"
server.host = \"0.0.0.0\" -- open to all addresses
server.port = 2222 -- default port

local function test(client_id, command, args)
    _ = args
    server.printClient(client_id, command, \"test done\")
end

server.registerCommand(\"/test\", test)
" > bin/init.lua

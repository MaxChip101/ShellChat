server.title = "chat_server"
server.host = "0.0.0.0" -- open to all addresses
server.port = 2222 -- default port

server.manage_whitelist_rank = 255 -- minimum rank to manage the whitelist
server.manage_channel_rank = 255 -- minimum rank to manage channels
server.max_clients = 10
server.accept_timeout = 50
server.read_timeout = 50

local function test(client_id, command, args)
    _ = args
    server.printClient(client_id, command, "test done")
end

server.registerCommand("/test", test)

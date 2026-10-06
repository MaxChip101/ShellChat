# runs the other shell files in order in this project
./gen.sh
./make_config.sh
zig build --release=fast -p ./

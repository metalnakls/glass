# Transmission Source Dependency

Glass embeds libtransmission for local torrent downloads.

`REVISION` pins the Transmission source commit used by the build script. The
source checkout itself is created under `Vendor/transmission/source` by
`Scripts/build-libtransmission.sh` and is intentionally not copied from any
local Transmission checkout.

The build requires CMake. On developer Macs, install it with:

```sh
brew install cmake
```

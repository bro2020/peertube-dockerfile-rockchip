# peertube-dockerfile-rockchip
A special peertube image dockerfile for devices with rockchip CPUs with support for hardware acceleration ffmpeg-rockchip

The build uses the `ffmpeg-rockchip` project:

- https://github.com/nyanmisaka/ffmpeg-rockchip

Example:
```
docker build --force-rm --build-arg PEERTUBE_VERSION=v7.2.3 -t 'peertube-rockchip' .
```

Builded image available on Docker Hub:

```
docker pull bro2020/peertube-rockchip:latest
```

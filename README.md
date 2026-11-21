# droid-kit

基于官方 reDroid Android 13 的 Docker 镜像。`Dockerfile` 通过多架构索引摘要固定上游版本，继承上游启动配置，并添加 `droid-kit` 镜像标签信息。

## 构建

需要 Bash、Docker 和 Docker Buildx。`./build.sh [tag]` 每次构建一个目标架构并将镜像载入本机 Docker。默认架构为 `linux/amd64`，默认标签为 `13`。

```bash
./build.sh
PLATFORM=linux/arm64 ./build.sh 13-arm64
```

## 检查和导出

```bash
docker image inspect --format '{{.Os}}/{{.Architecture}} {{json .Config.Entrypoint}}' droid-kit:13
docker image inspect --format '{{.Os}}/{{.Architecture}} {{json .Config.Entrypoint}}' droid-kit:13-arm64
docker save -o ../droid-kit-13-arm64.tar droid-kit:13-arm64
```

运行镜像的 Linux 宿主机需要 Android Binder 支持。[reDroid 官方指南](https://github.com/remote-android/redroid-doc#getting-started)

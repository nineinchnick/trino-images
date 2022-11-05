# trino-images
Build additional container images for the Trino project

## core

Trino images with all plugins removed, except JMX and memory. Useful for building custom Trino images with additional third-party plugins (connectors).

All images are built using the original Dockerfile and other resources and original artifacts published by the Trino project. Build script available at https://github.com/nineinchnick/trino-images

Published as [nineinchnick/trino-core](https://hub.docker.com/repository/docker/nineinchnick/trino-core).

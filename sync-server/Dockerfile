FROM dart:3.9 AS build
WORKDIR /src
COPY pubspec.yaml ./
RUN dart pub get
COPY . .
RUN dart pub get --offline && dart compile exe bin/server.dart -o /server

FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /server /server
ENV DATA_DIR=/data PORT=8080
EXPOSE 8080
CMD ["/server"]

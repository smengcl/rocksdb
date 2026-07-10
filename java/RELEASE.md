## Cross-building

RocksDB can be built as a single self-contained fat JAR from the source tree.

Building the fat JAR requires:

 * [Docker](https://www.docker.com/docker-community)
 * A macOS machine that can build the `osx` JNI libraries
 * Java 8 set as `JAVA_HOME`
 * `mingw-w64` installed for the `win64` JNI library

From RocksDB's root source directory, run:

    make jclean clean rocksdbjavastaticfatjar

This is the supported one-command fat-jar build. It builds:

 * macOS: `osx-arm64`, `osx-x86_64`
 * Linux glibc via Zig `*-linux-gnu`: `linux32`, `linux64`, `linux-aarch64`, `linux-ppc64le`, `linux-s390x`, `linux-riscv64`
 * Linux musl via Zig `*-linux-musl`: `linux32-musl`, `linux64-musl`, `linux-aarch64-musl`, `linux-ppc64le-musl`, `linux-s390x-musl`
 * Windows: `win64`

For compatibility, `make rocksdbjavastaticreleasedocker` now delegates to the same fat-jar target.

You can find the native binaries and JARs in `java/target` upon completion, including:

    librocksdbjni-linux32.so
    librocksdbjni-linux64.so
    librocksdbjni-linux32-musl.so
    librocksdbjni-linux64-musl.so
    librocksdbjni-linux-aarch64.so
    librocksdbjni-linux-aarch64-musl.so
    librocksdbjni-linux-ppc64le.so
    librocksdbjni-linux-ppc64le-musl.so
    librocksdbjni-linux-s390x.so
    librocksdbjni-linux-s390x-musl.so
    librocksdbjni-linux-riscv64.so
    librocksdbjni-osx-arm64.jnilib
    librocksdbjni-osx-x86_64.jnilib
    librocksdbjni-win64.dll
    rocksdbjni-x.y.z-javadoc.jar
    rocksdbjni-x.y.z-linux32.jar
    rocksdbjni-x.y.z-linux64.jar
    rocksdbjni-x.y.z-linux32-musl.jar
    rocksdbjni-x.y.z-linux64-musl.jar
    rocksdbjni-x.y.z-osx.jar
    rocksdbjni-x.y.z-win64.jar
    rocksdbjni-x.y.z-sources.jar
    rocksdbjni-x.y.z.jar

Where x.y.z is the built version number of RocksDB.

## Maven publication

Set ~/.m2/settings.xml to contain:

    <settings xmlns="http://maven.apache.org/SETTINGS/1.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:schemaLocation="http://maven.apache.org/SETTINGS/1.0.0 http://maven.apache.org/xsd/settings-1.0.0.xsd">
      <servers>
        <server>
          <id>sonatype-nexus-staging</id>
          <username>your-sonatype-jira-username</username>
          <password>your-sonatype-jira-password</password>
        </server>
      </servers>
    </settings>

From RocksDB's root directory, first build the Java static JARs:

    make jclean clean rocksdbjavastaticpublish

This command will [stage the JAR artifacts on the Sonatype staging repository](http://central.sonatype.org/pages/manual-staging-bundle-creation-and-deployment.html). To release the staged artifacts.

1. Go to [https://oss.sonatype.org/#stagingRepositories](https://oss.sonatype.org/#stagingRepositories) and search for "rocksdb" in the upper right hand search box.
2. Select the rocksdb staging repository, and inspect its contents.
3. If all is well, follow [these steps](https://oss.sonatype.org/#stagingRepositories) to close the repository and release it.

After the release has occurred, the artifacts will be synced to Maven central within 24-48 hours.

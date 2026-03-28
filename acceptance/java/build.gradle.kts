plugins {
    java
    application
}

group = "md.remit.acceptance"
version = "0.0.1"

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(17))
    }
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("md.remit:remit-sdk")
    implementation("com.fasterxml.jackson.core:jackson-databind:2.17.0")
    implementation("org.web3j:core:4.10.3")
}

application {
    mainClass.set("App")
}

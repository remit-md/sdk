import org.jetbrains.kotlin.gradle.tasks.KotlinCompile

plugins {
    java
    jacoco
    signing
    kotlin("jvm") version "1.9.23"
    `maven-publish`
}

group = "md.remit"
version = "0.1.1"

java {
    withSourcesJar()
    withJavadocJar()
}

kotlin {
    jvmToolchain(17)
}

repositories {
    mavenCentral()
}

dependencies {
    // JSON serialization
    implementation("com.fasterxml.jackson.core:jackson-databind:2.17.0")
    implementation("com.fasterxml.jackson.datatype:jackson-datatype-jsr310:2.17.0")

    // HTTP client — Java 11 built-in, no extra dep needed

    // Ethereum / EIP-712 signing
    implementation("org.web3j:core:4.10.3")

    // BigDecimal utilities (precise decimal arithmetic for USDC amounts)
    // Java BigDecimal is sufficient — no extra lib needed

    // Spring AI (optional integration, compileOnly so it's not required at runtime)
    compileOnly("org.springframework.ai:spring-ai-core:1.0.0-M6")
    compileOnly("org.springframework:spring-context:6.1.6")

    // LangChain4j (optional integration)
    compileOnly("dev.langchain4j:langchain4j-core:0.30.0")

    // Test dependencies
    testImplementation(platform("org.junit:junit-bom:5.10.2"))
    testImplementation("org.junit.jupiter:junit-jupiter")
    testRuntimeOnly("org.junit.platform:junit-platform-launcher")
    testImplementation("org.assertj:assertj-core:3.25.3")
    testImplementation("org.springframework.ai:spring-ai-core:1.0.0-M6")
    testImplementation("dev.langchain4j:langchain4j-core:0.30.0")
}

tasks.test {
    useJUnitPlatform {
        excludeTags("acceptance")
    }
    finalizedBy(tasks.jacocoTestReport)
}

tasks.register<Test>("acceptanceTest") {
    useJUnitPlatform {
        includeTags("acceptance")
    }
    testLogging {
        events("passed", "failed", "skipped", "standard_out", "standard_error")
        showExceptions = true
        showStandardStreams = true
    }
}

tasks.jacocoTestReport {
    dependsOn(tasks.test)
    reports {
        xml.required.set(true)
        html.required.set(true)
    }
}

// Target from MASTER.md: 50%. Initial gate: 35% (compliance tests skipped without server).
tasks.jacocoTestCoverageVerification {
    violationRules {
        rule {
            limit {
                counter = "LINE"
                value = "COVEREDRATIO"
                minimum = "0.35".toBigDecimal()
            }
        }
    }
}

tasks.withType<KotlinCompile> {
    kotlinOptions.jvmTarget = "17"
}

publishing {
    publications {
        create<MavenPublication>("mavenJava") {
            from(components["java"])
            artifactId = "remit-sdk"
            pom {
                name.set("remit.md Java/Kotlin SDK")
                description.set("Java and Kotlin SDK for remit.md — universal USDC payment protocol for AI agents")
                url.set("https://remit.md")
                licenses {
                    license {
                        name.set("MIT License")
                        url.set("https://opensource.org/licenses/MIT")
                    }
                }
                developers {
                    developer {
                        id.set("remit-md")
                        name.set("remit.md")
                        email.set("hello@remit.md")
                    }
                }
                scm {
                    connection.set("scm:git:git://github.com/remit-md/sdk.git")
                    developerConnection.set("scm:git:ssh://github.com/remit-md/sdk.git")
                    url.set("https://github.com/remit-md/sdk")
                }
            }
        }
    }
    // Publishing to Maven Central is handled via bundle upload in CI.
    // Use `gradle publishToMavenLocal` to stage artifacts, then upload the bundle.
}

signing {
    val signingKey = System.getenv("GPG_PRIVATE_KEY_DECODED") ?: System.getenv("GPG_PRIVATE_KEY")
    val signingPassword = System.getenv("GPG_PASSPHRASE")
    if (signingKey != null && signingPassword != null) {
        useInMemoryPgpKeys(signingKey, signingPassword)
        sign(publishing.publications["mavenJava"])
    }
}

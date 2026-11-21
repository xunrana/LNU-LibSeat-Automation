allprojects {
    buildscript {
        repositories {
            maven { url = uri("https://maven.aliyun.com/repository/google") }
            maven { url = uri("https://maven.aliyun.com/repository/public") }
            maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
            google()
            mavenCentral()
        }
    }
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)

    afterEvaluate {
        if (project.name != "app") {
            val androidExt = project.extensions.findByName("android")
            if (androidExt != null) {
                try {
                    val m = androidExt.javaClass.getMethod("compileSdkVersion", Int::class.javaPrimitiveType)
                    m.invoke(androidExt, 36)
                } catch (_: Throwable) {
                    try {
                        val m2 = androidExt.javaClass.getMethod("setCompileSdk", Integer::class.java)
                        m2.invoke(androidExt, 36)
                    } catch (_: Throwable) {}
                }
            }
        }
    }
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

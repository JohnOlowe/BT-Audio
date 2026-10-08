/*
 * The one class javac/ECJ need but android.jar does not have.
 *
 * android.jar has java/lang/invoke/{CallSite,MethodHandle,MethodHandles,
 * MethodType,...} but no LambdaMetafactory, so `-source 8` compilation of any
 * lambda fails with "the type java.lang.invoke.LambdaMetafactory cannot be
 * resolved. It is indirectly referenced from required .class files".
 *
 * AGP solves this with core-lambda-stubs.jar from build-tools. This file is
 * that stub: signatures only, never executed (D8 desugars the lambda or, at
 * minSdk 24+, the device runtime provides the real implementation).
 * setup.sh compiles it into vendor/core-lambda-stubs.jar and lib.sh puts it on
 * ECJ's bootclasspath.
 */
package java.lang.invoke;

public final class LambdaMetafactory {

    private LambdaMetafactory() {
    }

    public static CallSite metafactory(MethodHandles.Lookup caller,
                                       String invokedName,
                                       MethodType invokedType,
                                       MethodType samMethodType,
                                       MethodHandle implMethod,
                                       MethodType instantiatedMethodType) {
        throw new UnsupportedOperationException("core-lambda-stubs: compile-time stub");
    }

    public static CallSite altMetafactory(MethodHandles.Lookup caller,
                                          String invokedName,
                                          MethodType invokedType,
                                          Object... args) {
        throw new UnsupportedOperationException("core-lambda-stubs: compile-time stub");
    }
}

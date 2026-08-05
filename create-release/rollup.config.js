import commonjs from "@rollup/plugin-commonjs";
import resolve from "@rollup/plugin-node-resolve";
import typescript from "@rollup/plugin-typescript";

// The runner has no npm, so dependencies are bundled into a single committed file
// rather than installed at job time.
export default {
  input: "src/main.ts",
  output: { file: "dist/index.js", format: "es", sourcemap: false },
  plugins: [
    typescript({ tsconfig: "./tsconfig.json", noEmit: false, declaration: false }),
    resolve({ preferBuiltins: true }),
    commonjs(),
  ],
};

const path = require("path");
const nodeExternals = require("webpack-node-externals");

module.exports = {
  entry: "./index.js",
  output: {
    path: path.resolve(__dirname + "/build"),
    publicPath: "/",
    filename: "nodeapilogger.js",
    clean: true,
    libraryTarget: "commonjs2",
  },
  target: "node",
  module: {
    rules: [
      {
        test: /\.(js|ts)$/,
        exclude: [path.resolve(__dirname, "node_modules")],
        use: ["babel-loader"],
      },
    ],
  },
  externalsPresets: { node: true },
  externals: [nodeExternals()],
  optimization: {
    splitChunks: {
      chunks: "async",
      minSize: 20000,
      minRemainingSize: 0,
      minChunks: 1,
      maxAsyncRequests: 30,
      maxInitialRequests: 30,
      enforceSizeThreshold: 50000,
      cacheGroups: {
        defaultVendors: {
          test: /[\\/]node_modules[\\/]/,
          priority: -10,
          reuseExistingChunk: true,
        },
        default: {
          minChunks: 2,
          priority: -20,
          reuseExistingChunk: true,
        },
      },
    },
  },
  performance: {
    hints: false,
    maxEntrypointSize: 512000,
    maxAssetSize: 512000,
  },
};

const MiniCssExtractPlugin = require('mini-css-extract-plugin');
const path = require('path');
console.log(path.resolve('../public/static/css/'));

module.exports = {
  mode: 'production',
  entry: {
    light: './src/light/index.scss',
    dark: './src/dark/index.scss',
  },
  output: {
    path: path.resolve('../public/static/css/'),
  },
  plugins: [
    new MiniCssExtractPlugin({
      filename: '[name].min.css',
      chunkFilename: '[id].css',
    }),
  ],
  module: {
    rules: [
      {
        test: /\.s?css$/,
        use: [
          MiniCssExtractPlugin.loader,
          {
            loader: 'css-loader',
            options: {
              importLoaders: 2,
            },
          },
          {
            loader: 'postcss-loader',
            options: {
              ident: 'postcss',
              plugins: loader => [
                require('postcss-preset-env')(),
                require('cssnano')(),
              ],
            },
          },
          'sass-loader',
        ],
      },
    ],
  },
};

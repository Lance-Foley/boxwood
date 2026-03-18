FROM ruby:3.4.4-slim-bookworm

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    libyaml-dev \
    git \
    curl \
    postgresql-client \
    && rm -rf /var/lib/apt/lists/*

# Node.js 20 via nodesource
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - && \
    apt-get install -y --no-install-recommends nodejs && \
    rm -rf /var/lib/apt/lists/*

# Yarn
RUN npm install -g yarn

WORKDIR /app

# Pre-install gems from main branch (baked into image for speed)
COPY Gemfile Gemfile.lock ./
RUN bundle install --jobs 4

# Pre-install node modules from main branch
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile

# Install foreman (used by bin/dev to run Procfile.dev: web + css)
RUN gem install foreman

# Entrypoint handles dependency drift and DB init
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh
ENTRYPOINT ["docker-entrypoint.sh"]

# Default: run the dev server via foreman (Puma + Tailwind watcher)
CMD ["foreman", "start", "-f", "Procfile.dev"]

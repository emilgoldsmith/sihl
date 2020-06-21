build:
	@dune build @install

clean:
	@dune clean

test-all:
	SIHL_ENV=test dune runtest --force --no-buffer sihl
	SIHL_ENV=test DATABASE=mariadb dune runtest --force --no-buffer sihl_contrib/user
	SIHL_ENV=test DATABASE=postgres dune runtest --force --no-buffer sihl_contrib/user

test-dev:
	SIHL_ENV=test DATABASE=postgres dune runtest --no-buffer -w

test-core:
	SIHL_ENV=test dune runtest -w sihl

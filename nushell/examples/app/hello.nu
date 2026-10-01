use lib/shout.nu

# Greets `name`, loudly.
def main [name: string = "world"] {
    print (shout greet $name)
}

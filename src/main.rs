use hello_bindgen::hello;

fn main() {
    unsafe {
        println!("c hello returns {}.", hello());
    }
}
